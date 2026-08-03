setup &RedisProxyTestCase::GenericSetup

def proxy_used_memory(client)
    info = client.proxy('info', 'memory')
    match = info.match(/^used_memory:(\d+)$/)
    assert_not_nil(match, "Missing used_memory in PROXY INFO MEMORY: #{info}")
    match[1].to_i
end

test "PING without an argument returns PONG" do
    assert_equal(@proxy.ping, 'PONG')
end

test "PING with an argument echoes it as a bulk string" do
    payload = "health-check\x00payload"
    assert_equal(@proxy.ping(payload), payload)
end

test "PING rejects more than one argument" do
    reply = redis_command(@proxy.redis, :ping, 'one', 'two')
    assert_redis_err(reply)
    assert_not_nil(reply.to_s.downcase['wrong number of arguments'])
end

test "PING releases locally handled requests on persistent connections" do
    client = @proxy.redis
    before = proxy_used_memory(client)
    10_000.times do
        assert_equal(client.ping, 'PONG')
    end
    after = proxy_used_memory(client)

    # Allow allocator bookkeeping and output-buffer growth, but not the
    # clientRequest-per-PING growth that caused the production OOM loop.
    assert(after - before < 64 * 1024,
        "PING leaked #{after - before} bytes on one persistent connection")
end
