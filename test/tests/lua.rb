setup &RedisProxyTestCase::GenericSetup

test "EVAL supports zero keys and ARGV" do
    reply = @proxy.eval('return ARGV[1]', [], ['lua-arg'])
    assert_equal(reply, 'lua-arg')
end

test "EVAL routes declared keys without treating ARGV as a key" do
    key = '{lua-eval}:key'
    reply = @proxy.eval(
        'return redis.call("SET", KEYS[1], ARGV[1])',
        [key],
        ['lua-value']
    )
    assert_equal(reply, 'OK')
    assert_equal(@proxy.get(key), 'lua-value')
    @proxy.del(key)
end

test "SCRIPT LOAD and EVALSHA work through the proxy" do
    script = 'return {KEYS[1],ARGV[1]}'
    sha = @proxy.script(:load, script)
    assert_not_nil(sha)
    assert_equal(@proxy.script(:exists, sha), [true])
    assert_equal(@proxy.evalsha(sha, ['{lua-sha}:key'], ['value']),
                 ['{lua-sha}:key', 'value'])
end

test "SCRIPT EXISTS aggregates every master and every SHA" do
    loaded = @proxy.script(:load, 'return 1')
    missing = '0000000000000000000000000000000000000000'
    assert_equal(@proxy.script(:exists, loaded, missing), [true, false])
end

test "SCRIPT FLUSH and reload are consistent across every master" do
    script = 'return redis.call("SET",KEYS[1],ARGV[1])'
    sha = @proxy.script(:load, script)
    assert_equal(@proxy.script(:exists, sha), [true])
    assert_equal(@proxy.script(:flush), 'OK')
    assert_equal(@proxy.script(:exists, sha), [false])

    sha = @proxy.script(:load, script)
    assert_equal(@proxy.evalsha(sha, ['{lua-reload}:key'], ['reloaded']), 'OK')
    assert_equal(@proxy.get('{lua-reload}:key'), 'reloaded')
    @proxy.del('{lua-reload}:key')
end

test "EVAL supports multiple keys in the same hash slot" do
    keys = ['{lua-multi}:one', '{lua-multi}:two']
    reply = @proxy.eval(
        'redis.call("SET",KEYS[1],ARGV[1]); ' \
        'redis.call("SET",KEYS[2],ARGV[2]); return #KEYS',
        keys,
        ['one', 'two']
    )
    assert_equal(reply, 2)
    assert_equal(@proxy.mget(*keys), ['one', 'two'])
    @proxy.del(*keys)
end

test "SCRIPT HELP, DEBUG and KILL are routed without unsupported errors" do
    help = @proxy.script(:help)
    assert_class(help, Array)
    assert(help.join(' ').downcase['debug'])
    assert_equal(@proxy.script(:debug, :no), 'OK')

    kill = redis_command(@proxy.redis, :script, :kill)
    assert_redis_err(kill)
    assert(kill.to_s['NOTBUSY'])
end
