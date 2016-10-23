package WWW::Easy::AnyEvent;
use common::sense;
use EV;
use WWW::Easy::Auth;
use AnyEvent::HTTP::Server;
use JSON::XS;
use base qw(AnyEvent::HTTP::Server);

sub new { 	
	my ($class,%opt) = @_;
	my $KEY = $opt{token_key};
	my $apiprefix = $opt{api_prefix} || '/api';
	my %public_methods = $opt{public_methods} ? map { $_=>1 } @{ $opt{public_methods}} : ();
	my $self;
	$self = AnyEvent::HTTP::Server->new(
		%opt,
		cb => sub {
			my $request = shift;
			if ($request->[1] =~ m|^${apiprefix}/([-\w]+)|) { 
				my $method = $1;
				my $args = '';
				my %h = (headers=>{connection=>'close'});
				return sub {  # on body loaded:
					my ($final, $bodyref) = @_;
					$args.=$$bodyref;
					if(!$final) { 
						return;
					}
					eval {
						$args &&= JSON::XS::decode_json($args);
						$args ||= {};
						### toDo: ($R->headers_in->{'X-Requested-With'} eq 'XMLHttpRequest')  || return e404();
						if( $method eq 'login') { 
#							warn "login $args->[0], $args->[1]\n";			 
							$self->checkPassword( $args->[0], $args->[1], sub { 
								my $user_id = shift;
								$request->replyjs($user_id ? {user => $user_id } : {must_authenticate=>1, reason=>'Bad'}, 
									headers => { %{$h{headers}}, ($user_id ?  ("Set-Cookie" => 'u='.$self->makeToken($request,$user_id,$KEY)."; Path=/; HttpOnly")  : ())},
									## send token in headers
								);
							});

							return;
							### toDo:: check and sendToken or return { must_authenticate=>1, reason=>'Bad' });
						}
						my $user_id;
						if($opt{authentication} && !$public_method{$method}) {
							$user_id = $self->checkToken($request,'u',86400,$KEY);
							if(!$user_id) { 
								$request->replyjs(200, {must_authenticate=>1}, %h);
								return;
							}
						}
						my $func = $class->can("api_$method");
						if($func) { 
							$func->($args, $user_id, sub { 
								my $ret = shift;
								$request->replyjs(200, $ret , %h);
							});
						} else { 
							warn "Unknown method $method";
							$request->replyjs(404, {error=>"Unknown method $method"}, %h);
						}
					};
					if(my $err = $@) {
						warn "Error occured :", Data::Dumper::Dumper($method, $args, $err);
						$request->replyjs(500, {error=>'Error occured', ($opt{return_error} ? (detail=>$err) :() )}, %h);
					} 
				};
			} else { 
				my $uri = $request->[1]; 
				my $page = $uri;
				$page =~ s|^/+||gs;
				$page =~ s|[\./]|_|sg;
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
    return WWW::Easy::Auth::_check_token ($name, $token, $ipaddr, $ttl, $secret);
}


1;

=pod


=cut
