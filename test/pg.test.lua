#!/usr/bin/env tarantool

package.path = "../?/init.lua;./?/init.lua"
package.cpath = "../?.so;../?.dylib;./?.so;./?.dylib"

local pg = require('pg')
local json = require('json')
local tap = require('tap')
local f = require('fiber')

local host, port, user, pass, db = string.match(os.getenv('PG') or '',
    "([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)")

p, msg = pg.connect({ host = host, port = port, user = user, pass = pass, 
    db = db, raise = false, size = 2 })

if p == nil then error(msg) end

function test_old_api(t, c)
    t:plan(15)
    t:ok(c ~= nil, "connection")
    -- Add an extension to 'tap' module
    getmetatable(t).__index.q = function(test, stmt, result, ...)
        test:is_deeply(c:execute(stmt, ...), result,
            ... ~= nil and stmt..' % '..json.encode({...}) or stmt)
    end
    t:ok(c:ping(), "ping")
    if p == nil then
        return
    end
    t:q('SELECT 123::text AS bla, 345', {{ bla = '123', ['?column?'] = 345 }})
    t:q('SELECT -1 AS neg, NULL AS abc', {{ neg = -1 }})
    t:q('SELECT -1.1 AS neg, 1.2 AS pos', {{ neg = -1.1, pos = 1.2 }})
    t:q('SELECT ARRAY[1,2] AS arr, 1.2 AS pos', {{ arr = '{1,2}', pos = 1.2}})
    t:q('SELECT $1 AS val', {{ val = 'abc' }}, 'abc')
    t:q('SELECT $1 AS val', {{ val = 123 }}, 123)
    t:q('SELECT $1 AS val', {{ val = true }}, true)
    t:q('SELECT $1 AS val', {{ val = false }}, false)
    t:q('SELECT $1 AS val, $2 AS num, $3 AS str',
        {{ val = false, num = 123, str = 'abc'}}, false, 123, 'abc')
    t:q('SELECT * FROM (VALUES (1,2), (2,3)) t', {
        { column1 = 1, column2 = 2}, { column1 = 2, column2 = 3}})

    t:test("tx", function(t)
        t:plan(7)
        if not c:execute("CREATE TABLE _tx_test (a int)") then
            return
        end

        t:ok(c:begin(), "begin")
        c:execute("INSERT INTO _tx_test VALUES(10)");
        t:q('SELECT * FROM _tx_test', {{ a  = 10 }})
        t:ok(c:rollback(), "roolback")
        t:q('SELECT * FROM _tx_test', {})

        t:ok(c:begin(), "begin")
        c:execute("INSERT INTO _tx_test VALUES(10)");
        t:ok(c:commit(), "commit")
        t:q('SELECT * FROM _tx_test', {{ a  = 10 }})

        c:execute("DROP TABLE _tx_test")
    end)

    t:q('DROP TABLE IF EXISTS unknown_table', {})
    local tuples, reason = c:execute('DROP TABLE unknown_table')
    t:like(reason.message, 'unknown_table', 'error')
    c:free()
    print(555)
end

function test_gc(t, p)
    t:plan(1)
    p:get()
    local c = p:get()
    c = nil
    collectgarbage('collect')
    t:is(p.queue:count(), p.size, 'gc connections')
end

function test_pool_bind(t, p)
    t:plan(5)
    p:execute('CREATE TABLE tmptest (ID INTEGER);')
    p:begin()
    t:is(p.queue:count(), p.size - 1, 'start transaction')
    p:execute('INSERT INTO tmptest VALUES(4)')
    t:is(p.queue:count(), p.size - 1, 'continue transaction')
    p:execute('COMMIT')
    t:is(p.queue:count(), p.size, 'commit')
    p:begin()
    p:execute('INSERT INTO tmptest VALUES(5)')
    p:rollback()
    t:is(p.queue:count(), p.size, 'rollback')
    p:execute('BEGIN; DELETE FROM tmptest; ROLLBACK;')
    t:is(p.queue:count(), p.size, 'one statement transaction')
    p:execute('DROP TABLE tmptest')
end

function test_pool_fiber1(p, q)
    for i = 1, 10 do
        p:execute('BEGIN')
        p:execute('INSERT INTO tmptest VALUES ($1)', i)
        f.sleep(0.05)
        p:execute('ROLLBACK')
    end
    q:put(true)
end

function test_pool_fiber2(p, q)
    local res = true
    for i = 1, 50 do
        local r, m = p:execute('SELECT * from tmptest')
	if #r > 0 then
	    res = false
	end
	f.sleep(0.01)
    end
    q:put(res)
end

function test_pool_concurrent_fibers(p, q)
    for i = 1, 25 do
        local r, m = p:execute('SELECT pg_sleep(0.02)')
    end
    q:put(true)
end

function test_pool_concurrent(t, p)
    t:plan(2)
    p:execute('CREATE TABLE tmptest (ID INTEGER)')
    local q = f.channel(2)
    f.create(test_pool_fiber1, p, q)
    f.create(test_pool_fiber2, p, q)
    t:is(q:get() and q:get(), true, 'different transaction')
    local t1 = f.time()
    f.create(test_pool_concurrent_fibers, p, q)
    f.create(test_pool_concurrent_fibers, p, q)
    q:get()
    q:get()
    t:ok(f.time() - t1 < 0.6, 'parallel execution')
    p:execute('DROP TABLE tmptest')
end

function test_conn_fiber1(c, q)
    for i = 1, 10 do
        c:execute('SELECT pg_sleep(0.05)')
    end
    q:put(true)
end

function test_conn_fiber2(c, q)
    for i = 1, 25 do
        c:execute('SELECT pg_sleep(0.02)')
    end
    q:put(true)
end

function test_conn_concurrent(t, p)
    t:plan(1)
    local c = p:get()
    local q = f.channel(2)
    local t1 = f.time()
    f.create(test_conn_fiber1, c, q)
    f.create(test_conn_fiber2, c, q)
    q:get()
    q:get()
    t:ok(f.time() - t1 >= 0.95, 'concurrent connections')
end

tap.test('pool old api', test_old_api, p)
tap.test('connection old api', test_old_api, p:get())
tap.test('gc free connection', test_gc, p)
tap.test('pool bind connection', test_pool_bind, p)
tap.test('pool concurrent', test_pool_concurrent, p)
tap.test('connection concurrent', test_conn_concurrent, p)
p:get()
collectgarbage()
p:close()



