package WWW::Easy;
use strict;
use common::sense;
use Apache2::RequestRec;
use Apache2::RequestUtil;
use Apache2::RequestIO;
use Apache2::Connection;
use Apache2::Cookie;
use Apache2::Request;
use Apache2::ServerRec;
use Apache2::Log;
use HTML::CTPP2;
use JSON::XS;
use Data::Dumper;
use Digest::MD5;
use Encode;
use HTML::Strip;
use base 'Exporter';
use POSIX qw(modf);
use Time::HiRes;

use WWW::Easy::Auth;
our $VERSION = "0.8";

use Carp;
our ($R, $APR, $URI, $ARGS, $VARS, $PATH, $TAIL, $ABSHOME, $USER, $CTPP, %CTPPS);
our @EXPORT=qw( $R $APR $URI $ARGS  $VARS $PATH $TAIL $ABSHOME $CTPP
	makeTemplatePage htmlPage xmlPage e404 e500 e403 redirect url_escape ajax u2 removeTags
	request_content no_cache runTemplate from_json to_json
);

BEGIN { 
	$SIG{__WARN__} = sub {
		my $t = Time::HiRes::time();
		my ($s, $m, $h, $day, $mon, $year) = (localtime(int $t))[0 .. 5];
		print STDERR sprintf("[%04d-%02d-%02d %02d:%02d:%02d.%06d] [warn] [$$] [%s] ", $year+1900, $mon+1, $day, $h, $m, $s, int((POSIX::modf($t))[0]*1000000), ($R && $R->server ? $R->server->server_hostname : 'NoServer') ), @_;
	}
}
sub no_cache {
  $R->err_headers_out->add('Pragma', 'no-cache');
  $R->err_headers_out->add('Cache-control', 'no-cache,no-store');
  $R->err_headers_out->add('Expires', 'Mon, 10 Dec 2000 12:53:47 MSK');
}
sub handler {
  my ($r, $handlers, $standalone_args, $abs_home, $tz, $vars) = @_;

  my $rc =
  eval {
        my $template_dir = $r->dir_config('TEMPLATES');
        ($USER,$VARS,$TAIL,$ABSHOME) = (undef,$vars ||={},'', $r->headers_in->{'X-AbsHome'});
        $ABSHOME =~ s/:80\/?$//g;
        if($standalone_args) {
                ($R, $URI) = ($r, $r->uri);
                my $pool   = APR::Pool->new;
                my $ba     = APR::BucketAlloc->new($pool);
                my $bb     = APR::Brigade->new($pool, $ba);
                my $parser = APR::Request::Parser->urlencoded($pool, $ba, 'application/x-www-form-urlencoded');

                $APR = APR::Request::Custom->handle($pool,
                                 $standalone_args->{args},  
                                 '',
                                 $parser,
                                 10000,
                                 $bb)
        } else {
                ($R, $APR, $URI) = ($r, Apache2::Request->new($r), $r->uri);
        }
		$ARGS = scalar($APR->param());

		$CTPP = $CTPPS{$template_dir};

        if(!$CTPP) {
                $CTPP = new HTML::CTPP2(
                        steps_limit         => 10 * 1024*1024,
                );  
                $CTPP->include_dirs([grep { $_ } (
					$r->dir_config('CUSTOM_TEMPLATES'), $template_dir, split(',', $r->dir_config('LIB_TEMPLATES'))
				)]);
                $CTPPS{$template_dir} = $CTPP;
        }
        $URI=~s|^/+|/|;
      	$URI =~s|/index\.html$||;
        $URI =~s|\.html$||;
        $URI =~s|/$||;

        $VARS = { %$vars, 
				request=>{USER=>$USER, URI=>$URI, ARGS=>$ARGS,
                        URIQ=> ($ARGS->{from} || ($URI.'?'.$R->args)),
                        URIQQ=>$URI.'?'.$R->args, TAIL=>$TAIL, time=>time(),
                        URL => $abs_home.$URI,
                        HOME => $r->dir_config('HOME'),
                },
        } ;
        $VARS->{request}->{URIQ} =~ s/\?$//;


        # select handlers
        if (ref($handlers) eq 'CODE') {
                $handlers = $handlers->($VARS->{request});
        }
		if(!$URI) {  # Main page        
#               warn "Main page\n";
                return $handlers->{''}->();
        }
        while($URI) {  # try to find a handler
#               warn "uri=$URI t=$TAIL\n";
                if(my $handler = $handlers->{$URI}) {
                        return $handler->();
                }
                my $tail = ($URI=~m|(/[^/]*)$|)?$1:'';
                $TAIL = $VARS->{request}->{TAIL} = $tail.$TAIL;
                ($URI=~s|/[^/]*$||) or last;
                $VARS->{request}->{URI}=$URI;
        }
        # nothing found ?
        if(my $handler = $handlers->{__default}) {
               warn "__default handler\n";
                return $handler->();
        } 
        $R->status(404);
        return 404;
  };
  if($@) {
		if (ref($@) && $@->{code}) { 
			return $@->{code};
		}
        warn "executing request failed: $@";
        return 500;
  }
#  warn "$URI: returning rc=$rc st=".$R->status()." ll=".$R->status_line();
  return $rc==200 ? undef : $rc;
}
 
sub pageError {
  return makeTemplatePage('error', undef, error=>1);
}
sub eescape {
  my $x = shift;
  $x =~ s/(.)/sprintf("\\\\%03o",ord($1))/gse;
  return $x;
}

sub request_content { 
  my $max = shift || 10000000;
  my $buffer;
  my $ret = '';
  while ( $R->read($buffer, 4096) > 0 ) {
     $ret .=  $buffer;
	 die("Too large request") if length($ret)>$max;
  }
  return $ret;
}
 
sub redirect {
        my $url = shift;
		my $status = shift || 302;
        $R->status($status);
        $R->err_headers_out->add(Location=>$url);
        return $status;
}


sub url_escape { 
        my $x = $_[0];
        use bytes;
        $x=~s/([^0-9a-zA-Z])/sprintf("%%%02x",ord($1))/gsex;
        return $x;
}
sub html_escape {  
        my $x = $_[0];
        $x=~s/\&/&amp;/gs;
        $x=~s/</&lt;/gs;  
        $x=~s/>/&gt;/gs;
        return $x;
}
sub js_escape { 
        my $x = $_[0];
        $x =~ s/'/\\'/g;
        $x =~ s/"/\\"/g;
        $x =~ s/\n/\\n/g;
        return $x;
}
sub notFound {
        if(my $txt = $_[0]) { warn $txt; }
        $R->status(404);
        return 404;
}
sub serverError {
        if(my $txt = $_[0]) { warn $txt; }
        $R->status(500);
        return 500;
}
sub ajax {
        my $data = shift;
        $R->status(200); 
        $R->content_type('application/json');
#       warn JSON::XS::encode_json(utfize($data));
        if($data) { 
                $R->print(ref($data) ? JSON::XS::encode_json($data) : $data);  # if $data is a sclar, assume it is already JSON
        }
        return 200;
}

#################

sub api { 
	my %opt = @_;
	
	($R->headers_in->{'X-Requested-With'} eq 'XMLHttpRequest')  || return e404();
	my $content;
	my $length = $R->headers_in->{'Content-length'};
	$R->read($content, $length) if $length;
	my $data = $content ? JSON::XS::decode_json($content) : undef;
	$TAIL =~ s|^/||g;
	$TAIL =~ s|/+|/|g;
	((my $funcname), $TAIL) = split('/', $TAIL, 2);
	my $pkg = $opt{package} || (caller())[0];

	if($opt{auth}) {  
		my $key = $opt{auth}->{key} || die("No auth.key specified");
		my $cookie = $opt{auth}->{cookie} || 'u';
		if($funcname eq 'login') {
			my $user = ($opt{auth}->{check_password} || die("No auth.check_password specified"))->($data->[0], $data->[1]);
			if($user) { 
				WWW::Easy::sendToken($R, $cookie, $user->{id}, $key);  
    	        return ajax({ok=>1});
			} else {
				return ajax({must_authenticate=>1,reason=>'Bad'});
			}
		} elsif($funcname eq 'logout') { 
			WWW::Easy::clearToken($R, $cookie);
			return ajax({ok=>1});
		}
		my $user_id = WWW::Easy::checkToken($R, $cookie, 86400, $key);
		my $user = $user_id ? ($opt{auth}->{get_user} || die("No auth.get_user specified"))->($user_id) : undef;
		return ajax({must_authenticate=>1}) unless $user;
		{ no strict 'refs';
		  ${$pkg.'::USER' } = $user;
		}
	}

	my $func = "api_$funcname";

    if (my $code = $pkg->can($func)) {
		my $ret = eval { &$code($data, {__package__=>$pkg}); };

		if (my $err = $@) {  # error!
			my $user_error = 'Internal error';
			warn "internl error = '$err'\n";
			if($err =~ /^DBD::Pg::db (\w+) failed: ERROR:\s+ORM:\s*(.*)$/s) {
				warn "JSON ORM error\n";
				$err = $2;
				if($err =~ /^\{/) { # если начинается на { - это JSON
					$user_error = eval { _extract_json_prefix($err) } || 'Incorrect JSON error message';
				} else { 
					$user_error = $err;
				}
			} elsif ($err =~ /^ERROR:\s+update or delete on table "([^"]+)" violates foreign key constraint "([^"]+)" on table "([^"]+)"/) { 
			warn "Ref error\n";
				$user_error = { error => 'integrity', table => $3 };
			} else { 
				warn "other error [$err]\n";
			}
			return ajax({error=>$user_error});
		}
		return ajax($ret);
	} else { 
		return e404("func $func not found");
	} 
}


############################################### auth ########################
sub checkToken {
        my ($r, $name, $ttl, $secret) = @_;
        my $cookies = Apache2::Cookie->fetch($r);
        my $token = $cookies->{$name} || return undef;
		$token =~ s/^$name=//;
		my $ipaddr = $r->headers_in->{'X-Real-IP'};
		return WWW::Easy::Auth::_check_token ($name, $token, $ipaddr, $ttl, $secret);
}        

sub _make_token_key {
        my ($user_id, $time, $r, $secret) = @_;
        my $ipaddr = $r->headers_in->{'X-Real-IP'};
		return WWW::Easy::Auth::_make_token_key($user_id, $time, $ipaddr, $secret);
}

sub sendToken { 
        my ($r, $name, $user_id, $secret) = @_;
        my $now = time();
        my $cookie = join('!', _make_token_key ($user_id, $now, $r, $secret), $user_id, $now);
        my $coo = Apache2::Cookie->new($r,
			  -httponly => 1,
			  -secure   => ($r->headers_in()->{'X-AbsHome'} =~ m|^https://| ? 1 : 0),
              -name  => $name,
              -value => $cookie, 
              -path  => "/"
        );
        $coo->bake($r);
}
sub clearToken { 
		my ($r, $name) = @_;
		my $coo = Apache2::Cookie->new($r,
			-name  => $name,
            -value => '', 
            -path  => "/",
			-expires=>'-36M'
		);
		$coo->bake($r);
}       
    

####################################### templating ##########################
my %templateCache;
sub makeTemplatePage {
        my ($template,$type,%opt) = @_;
        
		if(ref($template) eq 'ARRAY') { 
			my $dir = $R->dir_config('CUSTOM_TEMPATES') || $R->dir_config('TEMPLATES');
			my $ok;
			foreach my $t (@$template) { 
				warn "search in $dir/$t\n";
				if(-f "$dir/$t.ctpp") { 
					$ok = $t; last;
				}
			}
			warn "found: $ok\n";
			if($ok) { $template = $ok; } 
			else { return 404; } 
		
		}
        my $obj ## devel! = $templateCache{$template}  ## do not autoreread if cache on!
                ||= $CTPP->parse_template("$template.ctpp");
        if(!$obj) { 
                my $e = $CTPP -> get_last_error();
				if( $e->{error_code} == 0x4000003  && $opt{with404} )  { 
					return 404;
				}
	            die "Template error: $template at line $e->{line} pos $e->{pos}: $e->{error_code} : $e->{error_str}";
        }
        $CTPP->reset();
        $CTPP->param($VARS);
        if(! $opt{error}) { 
                $R->status(200);
        }
        $R->content_type($type || 'text/html');
        $R->print($CTPP->output($obj));
        return 200; #$R->status();
}

 
sub runTemplate {
    my ($template, $opt) = @_;
	if(ref($template) eq 'ARRAY') { 
		my $dir = $R->dir_config('CUSTOM_TEMPATES') || $R->dir_config('TEMPLATES');
		my $ok;
		foreach my $t (@$template) { 
			warn "search in $dir/$t\n";
			if(-f "$dir/$t.ctpp") { 
				$ok = $t; last;
			}
		}
		warn "found: $ok\n";
		if($ok) { $template = $ok; } 
			else { return 404; } 
	}

    my $obj ## devel! = $templateCache{$template}  ## do not autoreread if cache on!
                ||= $CTPP->parse_template("$template.ctpp");
        if(!$obj) { 
                my $e = $CTPP -> get_last_error();
                die "Template error: $template at line $e->{line} pos $e->{pos}: $e->{error_code} : $e->{error_str}";
        }
        $CTPP->reset();
        $CTPP->param($opt);
    return $CTPP->output($obj);

}
 
sub htmlPage {
        my ($text) = @_;
        $R->status(200);
        $R->content_type('text/html');
        $R->print($text);
        return 200;
}
sub xmlPage {
        my ($text) = @_;
        $R->status(200);
        $R->content_type('text/xml');
        $R->print($text);
        return 200;
}

sub e404 {
        warn @_;
        return 404;
}
sub e500 {
        warn @_;
        return 500;
}
sub e403 {
        warn @_;
        return 403;
}

sub u2 { 
    my ($txt) = @_; 
    if(utf8::is_utf8($txt)) { return $txt; }
    return Encode::decode_utf8($txt);
}
sub from_json { 
	return JSON::XS::decode_json(Encode::encode_utf8(shift));
}
sub to_json { 
	return Encode::decode_utf8(JSON::XS::encode_json(shift));
}
sub _extract_json_prefix { 
    my $res = shift;
    return $res ? (JSON::XS->new->decode_prefix(Encode::encode_utf8($res)))[0] : undef;
}


sub removeTags { 
    my ($txt) = @_;
    my $hs = HTML::Strip->new();
    my $clean_text = $hs->parse( $txt );
    $hs->eof;
    return $clean_text;
}
1;
