use strict;
use DBI;
use Test::PostgreSQL;
use Test::More;
use JSON::XS;
use Encode;
use Cwd;
use ORM::Easy; 
use POSIX;

POSIX::setlocale( &POSIX::LC_MESSAGES, "C" );

my $dir = getcwd() . "/blib/lib";
my $pgsql = eval { Test::PostgreSQL->new( pg_config => qq|
 plperl.use_strict = on
 plperl.on_init    = 'use lib "$dir"; use ORM::Easy::SPI;'
 lc_messages       = 'C' #'ru_RU.UTF-8'
       |) }
or plan skip_all => $@;
 
plan tests => 15; 


my $sql = -d '/usr/local/share/orm-easy/' ? '/usr/local/share/orm-easy/' : '/usr/share/orm-easy/';

my $dbh = DBI->connect($pgsql->dsn);
ok(1);
$pgsql -> run_psql('-f', "$sql/00_idtype_int4.sql");
ok(1);
$pgsql -> run_psql('-f', "$sql/00_plperl.sql");
$pgsql -> run_psql('-f', "$sql/schema.sql");
$pgsql -> run_psql('-f', "$sql/id_seq.sql");
$pgsql -> run_psql('-f', "$sql/tables.sql");
$pgsql -> run_psql('-f', "$sql/rbac_tables.sql");
$pgsql -> run_psql('-f', "$sql/rbac_data.sql");
$pgsql -> run_psql('-f', "$sql/functions.sql");
$pgsql -> run_psql('-f', "$sql/rbac_functions.sql");
$pgsql -> run_psql('-f', "$sql/can_object.sql");
$pgsql -> run_psql('-f', "$sql/api_functions.sql");
$pgsql -> run_psql('-f', "$sql/store_file.sql");
$pgsql -> run_psql('-f', "$sql/presave__traceable.sql");
$pgsql -> run_psql('-f', "$sql/query__traceable.sql");
ok(1);

$dbh->do(q!CREATE TABLE public.object(id idtype, name text, x int) INHERITS (orm._traceable)!);
$dbh->do(q!INSERT INTO orm.metadata(name, public_readable) VALUES ('public.object', true)!);
$dbh->do(q!CREATE FUNCTION public.can_insert_object(user_id idtype, id_ text, data jsonb) RETURNS bool LANGUAGE sql AS $$ SELECT true; $$!);
$dbh->do(q!CREATE FUNCTION public.can_update_object(user_id idtype, id_ text, data jsonb) RETURNS bool LANGUAGE sql AS $$ SELECT true; $$!);
$dbh->do(q!CREATE FUNCTION public.get_test_version() RETURNS text LANGUAGE sql AS $$ SELECT 'a test version'; $$!);
$dbh->do(q!CREATE FUNCTION auth_interface.check_internal_user       (login_ text) RETURNS idtype LANGUAGE sql AS $$ SELECT CASE WHEN login_ = 'u' THEN 11 ELSE NULL END; $$!);
$dbh->do(q!CREATE FUNCTION auth_interface.add_or_check_internal_user(login_ text) RETURNS idtype LANGUAGE sql AS $$ SELECT CASE WHEN login_ = 'u' THEN 11 ELSE NULL END; $$!);

ok(1);

# define the daemon, later start it 

use WWW::Easy::AnyEvent;           # http api server template
use WWW::Easy::AnyEventPg;         # async PostgreSQL connect
use WWW::Easy::AnyEventORMAPI;     # HTTP ORM API (ORM::Easy) based on AnyEventPg

db_connect(\my $db, {     # test database
      dbname      => $pgsql->dbname,
      user        => 'postgres', 
      host        => $pgsql->socket_dir,
      port        => $pgsql->port
}, {});

my $http_port = '7001';

{ package _::Test::API;
  use base qw(WWW::Easy::AnyEvent);
  BEGIN { WWW::Easy::AnyEventPg->import; }
  $_::Test::API::expose_scalar_errors = 1;
  
  sub init { 
 	 WWW::Easy::AnyEventORMAPI::init($db);
  }
  sub api_version {
    my ($args, $user, $cb, $err_cb) = @_;
    db_query_rows( $db,
        ['SELECT public.get_test_version()'],
        sub {
            my $ret = shift->[0]->[0];
            $cb->({ api_version => $ret }); # headers=>{"Set-Cookie" => "x=v"});  
        },
        $err_cb
    );
  }
  sub api_test_scalar_error {
  	my ($args, $user, $cb, $err_cb) = @_;
  	my ($expose) = @$args;
  	warn "error exposition = $expose\n";
    db_query_rows( $db,
        ["DO LANGUAGE plpgsql \$\$ BEGIN RAISE EXCEPTION 'Bad happened'; END; \$\$"],
        sub {  $cb->({ ok=>1 }) },
        $err_cb, expose_scalar_errors => $expose
    );
  }
  sub api_test_json_error {
  	my ($args, $user, $cb, $err_cb) = @_;
    db_query_rows( $db,
        ["DO LANGUAGE plpgsql \$\$ BEGIN RAISE EXCEPTION '{\"key\":\"value\"}'; END; \$\$"],
        sub {  $cb->({ ok=>1 }) },
        $err_cb
    );
  }
  sub checkPassword { 
	  my ($self, $l, $p, $cb) = @_;  # проверяет пользователя об LDAP
	  if($l eq 'u' && $p eq 'v') {
	  	$cb->('u');
	  } else {
	  	$cb->(undef);
	  }
  }

}

my $pid = fork();
if($pid == 0) { #spawn the daemon
	my $srv = _::Test::API->new(
      port                => $http_port,
      authentication      => 1,
      verbose             => 1, # can be 2
      token_key           => 'test_token_key',
      auth_cookie_expires => 'Wed, 20 Oct 2100 00:00:00 GMT',
      public_methods      => ['version'],
      timeout             => 100
	);
	$srv->run;
	exit();
}



use POSIX ":sys_wait_h";
warn "killing $pid\n";
sub REAPER {
	1 while waitpid(-1, WNOHANG) > 0;
    $SIG{CHLD} = \&REAPER;  
};
$SIG{CHLD} = \&REAPER;

## call daemon api
use LWP::UserAgent;
use HTTP::CookieJar::LWP ();
my $jar = HTTP::CookieJar::LWP->new;
my $ua = LWP::UserAgent->new( cookie_jar => $jar );
    
sub call_api {
	my ($method, $args) = @_;
	my $req = HTTP::Request->new(POST => "http://localhost:$http_port/api/$method");
    $req->content_type('application/json');
	$req->content($args) if $args;
    my $res = $ua->request($req);
#    warn $req->as_string;
    if ($res->is_success) {
#		  warn $res->as_string;
#          warn $res->content;
          return $res->content;
    }
    else {
    	  die "$method($args) failed: ".$res->status_line;
    }
} 

sub call_api_ext { 
	my ($method, $args) = @_;
	my $req = HTTP::Request->new(POST => "http://localhost:$http_port/api/$method");
    $req->content_type('application/json');
	$req->content($args) if $args;
    my $res = $ua->request($req);
	return $res;
}

is (call_api("version") , '{"api_version":"a test version"}' , 'version');
is (call_api("login", '["u","v"]'), '{"user":"u"}', 'login');
#print Data::Dumper::Dumper([$jar->dump_cookies]);

is (normalize_json(call_api("mget", '["public.object", {},1,3]')), normalize_json({"list"=>[],"n"=>0}), 'empty mget');

foreach my $i (1..100) {
	$dbh->do(qq!SELECT orm_interface.save('public','object', NULL, 0, '{"id":$i, "name": "x$i", "x": $i}', '{}')!);
}

is(normalize_json(call_api("mget", '["public.object", {"x":7,"_fields":["id","name","x","created_by"]},1,1]')) ,
   normalize_json( {n=> "1", list => [ { id=>"7", x=>"7", name => 'x7', created_by => "0" }]}),
   'x7'
);

call_api("msave", '["public.object", {"_order":"id"},1,2,{"name":"xyz"}]');

is(normalize_json( call_api("mget", '["public.object", {"_order":"id","_fields":["id","name"]},1,4]')),
   normalize_json( {n=> "100", list => [ { id=>"1",name => 'xyz'}, { id=>"2",name => 'xyz'}, { id=>"3",name => 'x3'}, { id=>"4",name => 'x4'}]}),
   'msaved'
);


my $r1 = call_api_ext("test_scalar_error", '[]');
is($r1->code, "500", "Scalar error returns 500");
is($r1->content, '{"error":"Internal error"}', "Scalar error returns no details");

my $r2 = call_api_ext("test_json_error");
is($r2->code, "500", "JSON error returns 500");
is($r2->content, '{"error":{"key":"value"}}', "JSON error returns no details");

my $r3 = call_api_ext("test_scalar_error", '[1]');
is($r3->code, "500", "Scalar error returns 500 always");
is($r3->content, '{"error":"Bad happened"}', "Scalar error exposition");


kill HUP => $pid;
$pgsql->stop();
exit(0);

sub normalize_json {
	my ($x) = @_;
	my $json = JSON::XS->new->canonical(1);
	$x = $json->decode(Encode::encode_utf8($x)) unless ref($x);
	return $json->encode($x);
}



