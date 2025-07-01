package WWW::Easy::AnyEvent;
use strict;
use EV;
use WWW::Easy::Auth;
use WWW::Easy::Daemon; # for easy_try only
use AnyEvent::HTTP::Server;
use JSON::XS;
use Encode;
use POSIX qw(locale_h);
use base qw(AnyEvent::HTTP::Server);

sub new { 	
	my ($class,%opt) = @_;
	my $KEY     = delete $opt{token_key};
	my $verbose = delete $opt{verbose};
	my $apiprefix      = $opt{api_prefix} || '/api';
	my %public_methods = $opt{public_methods} ? map { $_=>1 } @{ $opt{public_methods}} : ();
	my %public_posts   = $opt{public_posts}   ? map { $_=>1 } @{ $opt{public_posts}} : ();
	my $token_ttl      = $opt{auth_token_ttl} || 86400;
	my %allowed_hm     = $opt{allowed_api_http_methods} ? map { $_=>1 } @{ $opt{allowed_api_http_methods}} : (POST=>1);
	my $self;

	setlocale(LC_TIME, "C");

	$self = AnyEvent::HTTP::Server->new(
		%opt,
		cb => sub {
			my $request = shift;
			my $http_method = $request->method;
			my $uri = $request->uri;
			warn "Request: $http_method $uri\n" if $verbose;
			my %h = (connection=>'close');
			if ($uri =~ m|^${apiprefix}/([-\w]+)|) { 
				my $method = $1;
				my $args = '';
				warn "API method $method called\n" if $verbose;
				return sub {  # on body loaded:
					my ($final, $bodyref) = @_;
					$args.=$$bodyref;
					if(!$final) { 
						return;
					}
					my $diehandler = $SIG{__DIE__};
                    $SIG{__DIE__} = undef;
					eval {
						$args &&= JSON::XS::decode_json($args);
						$args ||= {};
						if( %allowed_hm && ! $allowed_hm{$http_method}) { # not allowed http method
							warn "bad http method $http_method | allowed are:".join(' ', keys(%allowed_hm))."\n";
							$request->reply(400, 'Bad request');
							return;
						}
						if( $method eq 'login') { 
#							warn "login $args->[0], $args->[1]\n";			 
							$self->checkPassword( $args->[0], $args->[1], sub { 
								my $user_id = shift;
								$request->replyjs(
									($user_id ? {user => $user_id } : {must_authenticate=>1, reason=>'Bad'}), 
									headers => {
										%h, ($user_id ?  ("Set-Cookie" => 'u='.$self->makeToken($request,$user_id,$KEY)."; Path=/; HttpOnly".($opt{auth_cookie_expires} ? "; Expires=".$opt{auth_cookie_expires} : ""))  : ())
									},
									## send token in headers
								);
							});

							return;
							### toDo:: check and sendToken or return { must_authenticate=>1, reason=>'Bad' });
						}
						my $user_id;
						if($opt{authentication} && !$public_methods{$method}) {
							$user_id = $self->checkToken($request,'u',$token_ttl,$KEY);
							warn "got user=$user_id for k=$KEY t=$token_ttl k=".$request->headers->{cookie}."\n" if $verbose;
							warn Data::Dumper::Dumper($request->headers) if $verbose >= 2;
							if(!$user_id) { 
								warn "must auth for $method\n" if $verbose;
								$request->replyjs(200, {must_authenticate=>1}, headers=>\%h);
								return;
							}
						}
						my $check = $class->can("can_api_$method");   # (args, user_id, cb, context, error_cb) 
						my $func  = $class->can("api_$method");       # (args, user_id, cb, context, error_cb)  cb не должно возвращать скаляр!
						if(!$func) {
							warn "Unknown method $method";
							$request->replyjs(404, {error=>"Unknown method $method"}, headers=>\%h);
							return;
						}
						my %context;
						my $ok_cb = sub { 
							my ($ret, %opt) = @_;
							my %addh = $opt{headers} ? %{$opt{headers}} : ();
							if($opt{logout}) { 
								$addh{"Set-Cookie"} = "u=ram; Path=/; HttpOnly";
							} elsif( my $user_id = $opt{set_user_token})  {
								$addh{"Set-Cookie"} = 'u='.$self->makeToken($request,$user_id,$KEY)."; Path=/; HttpOnly".($opt{auth_cookie_expires} ? "; Expires=".$opt{auth_cookie_expires} : "");
							}
	#						warn "Replying for api method = $method ret=".Data::Dumper::Dumper($ret));
							if($opt{nojs}) {
								$request->reply(200, $ret, headers=>{  %h, %addh });
							} else {
								$request->replyjs(200, $ret , headers=>{  %h, %addh });
							}
						};
						my $err_cb = sub { 
							my $err = shift;
							return $request->replyjs(500, {error=>$err, ($opt{return_error} ? (detail=>$err) :() )}, headers=>\%h);
						};
						if($check) {
							$check->($args, $user_id, sub { 
								$func->($args, $user_id, $ok_cb, $err_cb, \%context, $request);
							}, sub {
								my $err = shift;
								$err_cb->($err);
							}, \%context );
						} else {
							$func->($args, $user_id, $ok_cb, $err_cb, \%context, $request);
						}
					};
					$SIG{__DIE__} = $diehandler;
					if(my $err = $@) {
						warn "Error occured :", Data::Dumper::Dumper($method, $args, $err);
						$request->replyjs(500, {error=>'Error occured', ($opt{return_error} ? (detail=>$err) :() )}, headers=>\%h);
					} 
				};
			} elsif($http_method eq 'POST') { 
				$uri =~ s|^/+||gs;
				$uri =~ s|[\./-]|_|sg;
				my ($user_id, %context);
				if($opt{authentication} && !$public_posts{$uri}) {
					$user_id = $self->checkToken($request,'u',$token_ttl,$KEY);
					warn "got user=$user_id\n" if $verbose;
                    if(!$user_id) { 
                    	warn "must auth\n" if $verbose;
                        $request->reply(400, 'Must authenticate for this POST', headers=>\%h);
                      	return;
                    }
				}
				if ($request->headers->{'content-type'} =~ m!^application/(json|x-www-form-urlencoded)!) {
					my $func = $self->can("post_$uri");
					my $format = $1;
					return {
							form => $func ? sub {
								my ($form, $text) = @_;
								my $data;
								my $diehandler = $SIG{__DIE__};
            			        $SIG{__DIE__} = undef;
								eval {
									if($format eq 'json') {
										$data = defined($text) && $text ne '' ? JSON::XS::decode_json(utf8::is_utf8($text) ? Encode::encode_utf8($text) : $text ) : undef;
									} else {
										$data = {};
										foreach my $k (keys %$form) { 
											my $v = $form->{$k};
											$data->{$k} = ref($v) eq 'aehts::av' ? [map { $_->[0] } @$v ] : $v->[0];
										}
									}
									$func->($data, $request, \%context, $user_id);
								};
								$SIG{__DIE__} = $diehandler;
								if(my $err = $@) {
									warn "Error occured in POST :", Data::Dumper::Dumper($uri, $data, $err);
									$request->reply(500, 'Error occured');
								}
							} : sub {
								$request->reply(404, 'No handler');
							}
											
					};
	
				} elsif($request->headers->{'content-type'} =~ m|^multipart/form-data|) { 
					my $func = $self->can("post_$uri");
					my %data;
					return { multipart => $func ? sub {
								my ($last, $part, $h) = @_;
								if ($h->{'content-disposition'} =~ /^form-data/) { 
									my $name = $h->{name};
									if ($name =~ /\S/) { 
										$data{$name} = $part;
									}
								} elsif (%$h) { 
									warn "Content disposition ".$h->{'content-disposition'}." not supported yet\n";
								}
								if($last) { 
									my $diehandler = $SIG{__DIE__};
    	        			        $SIG{__DIE__} = undef;
									eval { 
										$func->(\%data, $request, \%context, $user_id);
									};
									$SIG{__DIE__} = $diehandler;
									if(my $err = $@) {
										warn "Error occured in multipart POST :", Data::Dumper::Dumper($uri, \%data, $err);
										$request->reply(500, 'Error occured');
									}
								}
							 } : sub {
								my ($last, $part, $h) = @_;
								$request->reply(404, 'No handler') if $last;
							 }
					};
				} else {
					return sub {
						warn "No form handler for POST $uri ".$request->headers->{'content-type'}."\n";
						warn  Data::Dumper::Dumper($request);
						$request->reply(404, 'No handler');
					}
				}
			} else { 
				my $page = $uri;
				$page =~ s|^/+||gs;
				$page =~ s|[\./-]|_|sg;
				$page ||= 'main';
 				if (my $func = $self->can("page_$page")) { 
					eval { 
						$func->($request, undef, sub {
							$request->reply(@_);
						});
					};
					if(my $err = $@) {
						warn "Error occured in page :", Data::Dumper::Dumper($page, $err);
						$request->reply(500, 'Error occured');
					} 

				} else { 
					warn "Invalid URL ($page) ".$request->uri;
				  	$request->replyjs(404, {error=>'Invalid url'});
				}
			}
		}
	);
	return bless $self, $class;
}

sub run { 
	my $s = shift;
	$s->init;
	$s->listen;
	$s->accept;
	my $sig = AE::signal INT => sub {
		warn "Stopping server";
		$s->graceful(sub {
			warn "Server stopped";
			EV::unloop;
		});
	};
	EV::loop;
}
sub init {  # virtual function
}

sub makeToken { 
	my ($self, $r, $user_id, $secret) = @_;
	my $headers = $r->headers;
	my $ipaddr = $headers->{'x-real-ip'};
	my $now = scalar(time);
	return join('!', WWW::Easy::Auth::_make_token_key ($user_id, $now, $ipaddr, $secret), $user_id, $now);
}
sub checkToken { 
	my ($self, $r, $name, $ttl, $secret) = @_;
	my $cookies = {}; 
	my $headers = $r->headers;
	my $token = $headers->{'cookie+'.$name} || return undef;
	$token =~ s/^$name=//;
    my $ipaddr = $headers->{'x-real-ip'};
#warn "check token $token for $ipaddr\n";
    return WWW::Easy::Auth::_check_token ($name, $token, $ipaddr, $ttl, $secret);
}

sub url_escape { 
    my $x = $_[0];
    use bytes;
    $x=~s/([^0-9a-zA-Z])/sprintf("%%%02x",ord($1))/gsex;
    return $x;
}

1;

=pod


=cut
