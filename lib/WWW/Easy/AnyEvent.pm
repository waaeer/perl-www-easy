package WWW::Easy::AnyEvent;
use common::sense;
use EV;
use WWW::Easy::Auth;
use AnyEvent::HTTP::Server;
use JSON::XS;
use base qw(AnyEvent::HTTP::Server);

sub new { 	
	my ($class,%opt) = @_;
	my $KEY     = delete $opt{token_key};
	my $verbose = delete $opt{verbose};
	my $apiprefix      = $opt{api_prefix} || '/api';
	my %public_methods = $opt{public_methods} ? map { $_=>1 } @{ $opt{public_methods}} : ();
	my %public_posts   = $opt{public_posts}   ? map { $_=>1 } @{ $opt{public_posts}} : ();
	my $self;

	$self = AnyEvent::HTTP::Server->new(
		%opt,
		cb => sub {
			my $request = shift;
			my %h = (connection=>'close');
			if ($request->[1] =~ m|^${apiprefix}/([-\w]+)|) { 
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
						### toDo: ($R->headers_in->{'X-Requested-With'} eq 'XMLHttpRequest')  || return e404();
						if( $method eq 'login') { 
#							warn "login $args->[0], $args->[1]\n";			 
							$self->checkPassword( $args->[0], $args->[1], sub { 
								my $user_id = shift;
								$request->replyjs($user_id ? {user => $user_id } : {must_authenticate=>1, reason=>'Bad'}, 
									headers => { %h, ($user_id ?  ("Set-Cookie" => 'u='.$self->makeToken($request,$user_id,$KEY)."; Path=/; HttpOnly")  : ())},
									## send token in headers
								);
							});

							return;
							### toDo:: check and sendToken or return { must_authenticate=>1, reason=>'Bad' });
						}
						my $user_id;
						if($opt{authentication} && !$public_methods{$method}) {
							$user_id = $self->checkToken($request,'u',86400,$KEY);
							warn "got user=$user_id\n" if $verbose;
							if(!$user_id) { 
								warn "must auth\n";
								$request->replyjs(200, {must_authenticate=>1}, {headers=>\%h});
								return;
							}
						}
						my $check = $class->can("can_api_$method");
						my $func  = $class->can("api_$method");
						if(!$func) {
							warn "Unknown method $method";
							$request->replyjs(404, {error=>"Unknown method $method"}, headers=>\%h);
						}
						my %context;
						my $ok_cb = sub { 
							my ($ret, %opt,$action) = @_;
							my %addh = $opt{headers} ? %{$opt{headers}} : ();
							if($opt{logout}) { 
								$addh{"Set-Cookie"} = "u=ram; Path=/; HttpOnly";
							} elsif( my $user_id = $opt{set_user_token})  {
								$addh{"Set-Cookie"} = 'u='.$self->makeToken($request,$user_id,$KEY)."; Path=/; HttpOnly";
							}
	#						warn "Replying for api method = $method ret=".Data::Dumper::Dumper($ret));
							$request->replyjs(200, $ret , headers=>{  %h, %addh });
						};
						if($check) { 
							$check->($args, $user_id, sub { 
								$func->($args, $user_id, $ok_cb, \%context);								
							}, \%context, sub {
								my $err = shift;
								return $request->replyjs(500, {error=>$err, ($opt{return_error} ? (detail=>$err) :() )}, headers=>\%h);
							});
						} else {
							$func->($args, $user_id, $ok_cb, \%context);
						}
					};
					$SIG{__DIE__} = $diehandler;
					if(my $err = $@) {
						warn "Error occured :", Data::Dumper::Dumper($method, $args, $err);
						$request->replyjs(500, {error=>'Error occured', ($opt{return_error} ? (detail=>$err) :() )}, headers=>\%h);
					} 
				};
			} elsif($request->[0] eq 'POST') { 
				my $uri = $request->[1];
				$uri =~ s|^/+||gs;
				$uri =~ s|[\./-]|_|sg;
				my ($user_id, %context);
				if($opt{authentication} && !$public_posts{$uri}) {
					$user_id = $self->checkToken($request,'u',86400,$KEY);
					warn "got user=$user_id\n" if $verbose;
                    if(!$user_id) { 
                    	warn "must auth\n" if $verbose;
                        $request->reply(400, 'Must authenticate for this POST', {headers=>\%h});
                      	return;
                    }
				}
				if ($request->[2]->{'content-type'} eq 'application/x-www-form-urlencoded') {
					my $func = $self->can("post_$uri");
					return {
							form => $func ? sub {
								my ($form) = @_;
								my %data; 
								foreach my $k (keys %$form) { 
									my $v = $form->{$k};
									$data{$k} = ref($v) eq 'aehts::av' ? [map { $_->[0] } @$v ] : $v->[0];
								}
								my $diehandler = $SIG{__DIE__};
            			        $SIG{__DIE__} = undef;
								eval {
									$func->(\%data, $request, \%context, $user_id);
								};
								$SIG{__DIE__} = $diehandler;
								if(my $err = $@) {
									warn "Error occured in POST :", Data::Dumper::Dumper($uri, \%data, $err);
									$request->reply(500, 'Error occured');
								}
							} : sub {
								$request->reply(404, 'No handler');
							}
											
					};
				} elsif($request->[2]->{'content-type'} =~ m|^multipart/form-data|) { 
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
						warn "No form handler for POST $uri ".$request->[2]->{'content-type'}."\n";
						warn  Data::Dumper::Dumper($request);
						$request->reply(404, 'No handler');
					}
				}
			} else { 
				my $uri = $request->[1]; 
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
					warn "Invalid URL ($page) $request->[1]";
				  	$request->replyjs(404, {error=>'Invalid url'});
				}
			}
		}
	);
	return bless $self, $class;
}

sub run { 
	my $s = shift;
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
