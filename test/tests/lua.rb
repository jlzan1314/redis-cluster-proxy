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
