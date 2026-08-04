package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/zeromicro/go-zero/core/breaker"
	zredis "github.com/zeromicro/go-zero/core/stores/redis"
)

const (
	workers    = 20
	iterations = 1000
)

func failf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FAIL: "+format+"\n", args...)
	os.Exit(1)
}

func must(name string, err error) {
	if err != nil {
		failf("%s: %v", name, err)
	}
	fmt.Printf("PASS %-24s\n", name)
}

func main() {
	addr := "127.0.0.1:17779"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}

	rdb, err := zredis.NewRedis(zredis.RedisConf{
		Host:        addr,
		Type:        zredis.NodeType,
		Pass:        os.Getenv("REDIS_PASSWORD"),
		NonBlock:    false,
		PingTimeout: 3 * time.Second,
	})
	must("go-zero NewRedis(node)", err)
	if !rdb.Ping() {
		failf("PING returned false")
	}
	fmt.Printf("PASS %-24s value=PONG\n", "PING")

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	prefix := fmt.Sprintf("{gozero-proxy-%d}", time.Now().UnixNano())
	stringKey := prefix + ":string"
	counterKey := prefix + ":counter"
	configKey := prefix + ":config"
	luaKey := prefix + ":lua"
	defer func() {
		_, _ = rdb.Del(stringKey, counterKey, configKey, luaKey)
	}()

	must("SET", rdb.SetCtx(ctx, stringKey, "value"))
	got, err := rdb.GetCtx(ctx, stringKey)
	must("GET", err)
	if got != "value" {
		failf("GET value=%q, want value", got)
	}
	exists, err := rdb.ExistsCtx(ctx, stringKey)
	must("EXISTS", err)
	if !exists {
		failf("EXISTS returned false")
	}
	must("EXPIRE", rdb.ExpireCtx(ctx, stringKey, 300))
	ttl, err := rdb.TtlCtx(ctx, stringKey)
	must("TTL", err)
	if ttl <= 0 {
		failf("TTL=%d, want > 0", ttl)
	}
	value, err := rdb.IncrCtx(ctx, counterKey)
	must("INCR", err)
	if value != 1 {
		failf("INCR=%d, want 1", value)
	}

	fields := []string{
		"CommunityHotScore.BaseScore",
		"CommunityHotScore.LikeWeight",
		"CommunityHotScore.FavoriteWeight",
		"CommunityHotScore.ReplyWeight",
		"CommunityHotScore.DefaultPartitionCoefficient",
		"CommunityHotScore.DecayBaseFactor",
		"CommunityHotScore.DecayPeriodHours",
		"CommunityHotScore.MinimumTimeDecayFactor",
		"CommunityHotScore.FullSyncEnabled",
	}
	must("PIPELINE DEL/HSET/EXPIRE", rdb.PipelinedCtx(ctx, func(pipe zredis.Pipeliner) error {
		pipe.Del(ctx, configKey)
		for i, field := range fields {
			pipe.HSet(ctx, configKey, field, fmt.Sprintf(`{"name":%q,"value":%q}`, field, fmt.Sprint(i)))
		}
		pipe.Expire(ctx, configKey, 5*time.Minute)
		return nil
	}))
	items, err := rdb.HmgetCtx(ctx, configKey, fields...)
	must("HMGET", err)
	if len(items) != len(fields) {
		failf("HMGET len=%d, want %d", len(items), len(fields))
	}

	scriptBody := `return redis.call("SET", KEYS[1], ARGV[1])`
	sha, err := rdb.ScriptLoadCtx(ctx, scriptBody)
	must("SCRIPT LOAD", err)
	result, err := rdb.EvalShaCtx(ctx, sha, []string{luaKey}, "evalsha-value")
	must("EVALSHA keyed", err)
	if fmt.Sprint(result) != "OK" {
		failf("EVALSHA result=%v, want OK", result)
	}
	result, err = rdb.EvalCtx(ctx, `return redis.call("GET", KEYS[1])`, []string{luaKey})
	must("EVAL keyed", err)
	if fmt.Sprint(result) != "evalsha-value" {
		failf("EVAL result=%v, want evalsha-value", result)
	}
	script := zredis.NewScript(`return redis.call("SET", KEYS[1], ARGV[1])`)
	result, err = rdb.ScriptRunCtx(ctx, script, []string{luaKey}, "script-run-value")
	must("go-zero ScriptRun", err)
	if fmt.Sprint(result) != "OK" {
		failf("ScriptRun result=%v, want OK", result)
	}

	var commandErrors atomic.Int64
	var breakerOpen atomic.Int64
	var pingFalse atomic.Int64
	var wg sync.WaitGroup
	start := time.Now()
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iterations; i++ {
				if !rdb.PingCtx(ctx) {
					pingFalse.Add(1)
				}
				ok, err := rdb.ExistsCtx(ctx, configKey)
				if err != nil || !ok {
					commandErrors.Add(1)
					if errors.Is(err, breaker.ErrServiceUnavailable) {
						breakerOpen.Add(1)
					}
				}
				vals, err := rdb.HmgetCtx(ctx, configKey, fields...)
				if err != nil || len(vals) != len(fields) {
					commandErrors.Add(1)
					if errors.Is(err, breaker.ErrServiceUnavailable) {
						breakerOpen.Add(1)
					}
				}
			}
		}()
	}
	wg.Wait()
	elapsed := time.Since(start)
	fmt.Printf("LOAD total=%d ping=%d exists=%d hmget=%d elapsed=%s command_errors=%d ping_false=%d breaker_open=%d\n",
		workers*iterations*3, workers*iterations, workers*iterations, workers*iterations,
		elapsed.Round(time.Millisecond), commandErrors.Load(), pingFalse.Load(), breakerOpen.Load())
	if commandErrors.Load() != 0 || pingFalse.Load() != 0 || breakerOpen.Load() != 0 {
		failf("load validation failed")
	}
	fmt.Println("PASS go-zero breaker stayed closed")

	_, err = rdb.DelCtx(ctx, stringKey, counterKey, configKey, luaKey)
	must("DEL cleanup", err)
	fmt.Println("RESULT PASS")
}
