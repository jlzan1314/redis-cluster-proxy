setup &RedisProxyTestCase::GenericSetup

test "HELLO negotiates RESP2 without an upstream protocol switch" do
    reply = @proxy.redis.call('HELLO', 2)
    assert_class(reply, Array)
    hello = Hash[*reply]
    assert_equal(hello['server'], 'redis-cluster-proxy')
    assert_equal(hello['proto'], 2)
end

test "HELLO accepts the RESP3 negotiation used by go-redis v9" do
    reply = @proxy.redis.call('HELLO', 3)
    assert_class(reply, Array)
    hello = Hash[*reply]
    assert_equal(hello['server'], 'redis-cluster-proxy')
    assert_equal(hello['proto'], 3)
    assert_equal(@proxy.redis.ping, 'PONG')
end

test "CLIENT SETINFO accepts go-redis library identity" do
    assert_equal(@proxy.redis.call('CLIENT', 'SETINFO', 'LIB-NAME', 'go-redis'),
                 'OK')
    assert_equal(@proxy.redis.call('CLIENT', 'SETINFO', 'LIB-VER', '9.12.1'),
                 'OK')
end
