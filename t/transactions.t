use Test::Most 0.22;
use lib 't';
use RedisServer;
use RedisDB;
use IO::Select;
use Time::HiRes qw(usleep);

my $server = RedisServer->start;
plan( skip_all => "Can't start redis-server" ) unless $server;

my $redis = RedisDB->new( host => 'localhost', port => $server->{port} );
my $redis2 = RedisDB->new( { host => 'localhost', port => $server->{port}, lazy => 1, } );
plan( skip_all => "test requires redis-server version 2.0.0 and above" ) if $redis->version < 2;

subtest "With raise error" => sub {
    is $redis->multi, 'OK', "Entered transaction";
    is $redis->set( "key", "value" ), 'QUEUED', "Queued set";
    for (qw(this is a list)) {
        is $redis->rpush( "list", $_ ), 'QUEUED', "Queued push '$_'";
    }
    is $redis->lrange( "list", 0, 3 ), 'QUEUED', "Queued lrange";

    # You can pass hashref to constructor too
    is $redis2->set( "key", "wrong value" ), "OK", "Set key to wrong value";
    my $res = $redis->exec;
    eq_or_diff $res, [ 'OK', 1, 2, 3, 4, [qw(this is a list)] ], "Transaction was successfull";
    is $redis->get("key"), "value", "key set to correct value";
    throws_ok { $redis->get("list") } "RedisDB::Error",
      "raise_error is still set after transaction";

    if ( $redis->version >= 2.001 ) {
        is $redis->watch("watch"), "OK", "watch for watch";
        is $redis->multi, 'OK', "Entered transaction";
        dies_ok { $redis->multi } "multi can't be nested";
        is $redis->set( "key", "another value" ), "QUEUED", "QUEUED set";
        is $redis2->set( "watch", "changed" ), "OK", "Set watched key";
        is $redis->exec, undef, "Transaction failed";
        is $redis->get("key"), "value", "key wasn't changed";

        is $redis->multi, "OK", "Entered transaction";
        is $redis->set( "key", "another value" ), "QUEUED", "QUEUED set";
        is $redis->discard, "OK", "Discarded transaction";
        is $redis->get("key"), "value", "key wasn't changed";
    }

    note "must not reconnect while in multi";
    is $redis->multi, "OK", "Entered transaction";
    is $redis->set( "key", "42" ), "QUEUED", "QUEUED set";
    is $redis->quit, "OK", "QUIT";
    dies_ok { $redis->set( "key2", "43" ) } "Not reconnecting when in transaction";

    ok $redis->multi(RedisDB::IGNORE_REPLY), "Entered transaction (async)";
    is $redis->set( "key", "42" ), "QUEUED", "QUEUED set";
    is $redis->quit, "OK", "QUIT";
    dies_ok { $redis->set( "key2", "43" ) } "Not reconnecting when in transaction";

    note "must not reconnect when watching key";
    is $redis->watch("key"), "OK", "Watching key";
    is $redis->quit, "OK", "QUIT";
    dies_ok { $redis->set( "key2", "43" ) } "Not reconnecting when watching";

    ok $redis->watch( "key", RedisDB::IGNORE_REPLY ), "Watching key (async)";
    is $redis->quit, "OK", "QUIT";
    dies_ok { $redis->set( "key2", "43" ) } "Not reconnecting when watching";

    $redis = undef;
};

subtest "multi/exec without raise_error" => sub {

    # we need connection name support
    plan skip_all => "this test requires redis 2.6.9" if $redis2->version lt 2.006009;

    my $redis3 = RedisDB->new(
        host            => 'localhost',
        port            => $server->{port},
        raise_error     => undef,
        connection_name => 'test_connection_3',
    );

    my $kill_connection = sub {
        my ($r3) =
          map { $_->{addr} } grep { $_->{name} eq 'test_connection_3' } @{ $redis2->client_list };
        ok $r3, "Got address for test_connection_3";
        $redis2->client_kill($r3);
        IO::Select->new( $redis->{_socket} )->can_read;
    };

    note "inside transaction raise_error is always on";
    is $redis3->hset( "hash", "key", "value" ), 1, "Set hash key";
    my $res = $redis3->get("hash");
    isa_ok $res, "RedisDB::Error", "RedisDB returns error instead of throwing exception";
    is $redis3->multi, "OK", "Entered transaction";
    throws_ok { $redis3->execute("no-such-command") } "RedisDB::Error",
      "Inside transaction error raises exception";

    note "redis will not reconnect in the middle of transaction";
    $redis3->reset_connection;
    is $redis3->multi, "OK", "Entered transaction";
    $redis3->set( "test3", "test3" );
    $kill_connection->();
    throws_ok { $redis3->set( "test3", "42" ) } "RedisDB::Error::DISCONNECTED",
      "not reconnecting when in multi";

    note "must not reconnect when watching key";
    $redis3->reset_connection;
    is $redis3->watch("key"), "OK", "Watching key";
    $kill_connection->();
    throws_ok { $redis3->set( "test3", "42" ) } "RedisDB::Error::DISCONNECTED",
      "not reconnecting when watching";

    $redis3->reset_connection;
    is $redis3->watch("key"), "OK", "Watching key";
    is $redis3->unwatch, "OK", "Unwatched";
    $kill_connection->();
    is $redis3->ping, "PONG", "After unwatch it reconnects";

    note "exec should restore raise_error";
    $redis3->reset_connection;
    is $redis3->multi, "OK", "Entered transaction";
    is $redis3->get("test3"), "QUEUED", "queued get";
    is $redis3->get("hash"),  "QUEUED", "queued get hash";
    is $redis3->set( "test3", 43 ), "QUEUED", "queued set";
    $res = $redis3->exec;
    is $res->[0],     undef,            "first command returned undef";
    isa_ok $res->[1], "RedisDB::Error", "second command returned an error";
    is $res->[2],     "OK",             "last command returned OK";
    $res = $redis3->get("hash");
    isa_ok $res, "RedisDB::Error", "raise_error unset after transaction finished";
};

subtest "Reconnecting if disconnected after EXEC" => sub {
    my $server = Test::TCP->new(
        code => sub {
            my $port = shift;
            my $sock = IO::Socket::IP->new(
                LocalPort => $port,
                Listen    => 1,
            );
            while ( my $cli = $sock->accept ) {
                my $line;
                while ( defined( $line = <$cli> ) ) {
                    if ( $line =~ /MULTI/ ) {
                        $cli->send( "+OK\r\n", 0 );
                    }
                    elsif ( $line =~ /SET/ ) {
                        $cli->send( "+QUEUED\r\n", 0 );
                    }
                    elsif ( $line =~ /GET/ ) {
                        $cli->send( ":42\r\n", 0 );
                    }
                    elsif ( $line =~ /EXEC/ ) {
                        $cli->close;
                        last;
                    }
                }
            }
        }
    );
    my $redis = RedisDB->new( port => $server->port, raise_error => undef, );
    ok $redis->multi(RedisDB::IGNORE_REPLY), "Entered transaction (async)";
    is $redis->set( "key", "42" ), "QUEUED", "QUEUED set";
    my $repl;
    ok $redis->exec( sub { $repl = $_[1] } ), "Sent EXEC (async)";
    IO::Select->new( $redis->{_socket} )->can_read;
    is $redis->get("key"), 42, "Reconnected after EXEC";
    isa_ok $repl, "RedisDB::Error::DISCONNECTED", "EXEC callback received error";
};

done_testing;
