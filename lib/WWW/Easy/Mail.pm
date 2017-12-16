package WWW::Easy::Mail;
use common::sense;
use File::Type;
use File::Basename;
use MIME::Entity;
use Mail::Address;
use Email::Date::Format;
use Encode;

sub _get_boundary { 
	return sprintf('----_=_NextPart_%04i_%lx',int(rand(2e9)),time);
}

sub _build_text {
	my ($opt, $headers) = @_;
	return MIME::Entity->build(
		Top         => 0,
		%$headers,
		Type        => qq[text/plain; charset="utf-8"],
		Data        => _u2($opt->{text}),
		Encoding    => 'quoted-printable',
		Disposition => undef,
	);
}

sub _build_html { 
	my ($opt, $headers) = @_;
	return MIME::Entity->build (
		Top         => 0,
		%$headers,
		Type        => qq[text/html; charset="utf-8"],
		Data        => _u2($opt->{html}),
		Encoding    => 'quoted-printable',
		Disposition => undef,
	);
}

sub _build_html_with_inline {
	my ($opt, $headers) = @_;
	if (my $imgs = $opt->{inline})  { 
		my $cont = MIME::Entity->build(
			Top         => 0,
			%$headers,
            Type        => q[multipart/related],
            Boundary    => _get_boundary(),
            Encoding    => 'binary',
			"X-Mailer"  => undef,
        );
		$cont->add_part(_build_html($opt, {}));
		foreach my $img (@$imgs) { 
			my $type = File::Type->new()->mime_type($img);
			$cont->add_part( MIME::Entity->build (
				Type     => $type,
				Top      => 0,
				Encoding => 'base64',
				Disposition => 'inline',
				'Content-ID'=> '<'.basename($img).'>',
				Path     => $img
			));
		}
		return $cont;		
	} else { 
		return _build_html($opt, $headers);
	}
}

sub _build_text_and_html { 
	my ($opt, $headers) = @_;
	my $main;
	if($opt->{text} && $opt->{html}) { 
		$main = MIME::Entity->build (
			Top        => 0,
			%$headers,
			Type        => q[multipart/alternative],
            Boundary    => _get_boundary(),
            Encoding    => 'binary',
			"X-Mailer"  => undef,
        );
		$main->add_part( _build_text($opt, {}));
		$main->add_part( _build_html_with_inline($opt, {}));
	} elsif ($opt->{text} && ! $opt->{html}) { 
		$main = _build_text($opt, $headers);
	} elsif ($opt->{html} && ! $opt->{text}) { 
		$main = _build_html_with_inline($opt, $headers);
	} else { 
		die "No text in message";
	}
	return $main;
	
}
sub send {
	my %opt = @_;
	my $mailer = $opt{mail_client};
	my $class = "WWW::Easy::Mail::".$mailer->{mailer};
	if ($mailer->{mailer} !~ /^SMTP$/) { 
		die("Unknown mailer $mailer->{mailer}");
	}

	my $client = $class->new(%{ $mailer->{mailer_args} });
	my $message = _build(\%opt);
#	print $message->as_string."\n";
	$client->send($message, \%opt);
}

sub _serialize_addr { 
	my $addr = shift;
	return undef unless $addr;
	if (ref($addr) eq 'ARRAY') { 
		return join(',', map { 
			(ref($_) eq 'ARRAY') 
			? Mail::Address->new(_2u($_->[1]), $_->[0])->format()
			: $_
		} @$addr);
	} else { 
		return  encode('MIME-Header', _u2($addr));
	}
}
sub _build { 
	my $opt = shift;
	my $to     = $opt->{to};
	my $cc     = $opt->{cc};
	my $from   = $opt->{from};
	my $subject= $opt->{subject};

	my %email_header = (
		Top => 1,
		Subject => encode('MIME-Header', _2u($subject)),
		To      => encode('MIME-Header', _serialize_addr($to)),
		From    => encode('MIME-Header', _serialize_addr([$from])),
		Cc      => encode('MIME-Header', _serialize_addr([$cc])),
		'Message-ID' => '<'.encode('MIME-Header',sprintf('M_%04i%lx%d',int(rand(2e9)),time,$$). 
				(ref($from) eq 'ARRAY' ? $from->[0] : $from)
		).'>',
		Date    => Email::Date::Format::email_date(),
	);

	if(my $files = $opt->{attachment}) { 
		my $cont = MIME::Entity->build (
			%email_header,
			Type    	=> q[multipart/mixed],
			Boundary    => _get_boundary(),
			Encoding    => 'binary',
			"X-Mailer"  => undef,
		);
		$cont->add_part(_build_text_and_html($opt, {}));
		foreach my $f (@$files) { 
			$cont->attach(
				Path     => $f,
				Encoding => 'base64',
				Disposition => "attachment"
			);
#			my $type = File::Type->new()->mime_type($f);
#			$cont->add_part( MIME::Entity->build (
#				Type     => $type,
#				Top      => 0,
#				Encoding => 'base64',
#				Path     => $f
#			));
		}
		return $cont;
	} else { 
		return _build_text_and_html($opt,  \%email_header);
	}
}

sub _u2 { 
	if(utf8::is_utf8($_[0])) { 
		return Encode::encode_utf8($_[0]);
	} else { 
		return $_[0];
	}
}
sub _2u { 
	if(!utf8::is_utf8($_[0])) {   
        return Encode::decode_utf8($_[0]);
    } else { 
        return $_[0];
    }
}


package WWW::Easy::Mail::SMTP;
use Net::SMTP;
use IO::Socket::SSL;

sub new {
	my ($class, %opt) = @_;
	return bless {%opt}, $class;
}
sub send { 
	my ($self, $message, $opt) = @_;
	my $smtp = Net::SMTP->new (
		$self->{host},
		Port => $self->{port},
		SSL  => $self->{ssl},
		Hello => $self->{hello},
	) || die("Cannot connect SMTP server $self->{host}:$self->{port} with ssl=$self->{ssl}");
	if($self->{username}) { 
		my $ok = $smtp->auth( $self->{username}, $self->{password});
		if(!$ok) { 
			die("Cound not authenticate ($self->{username} $self->{password}) : ".$smtp->message);
		}
	}
	my $sender = ref($opt->{from}) eq 'ARRAY' ? $opt->{from}->[0] : $opt->{from};
#warn "semder=$sender\n";
	$smtp->mail($sender) || die("cannot send MAIL: $sender:".$smtp->message);
	my @recipients;
	if(my $to = $opt->{to}) { 
		if(ref($to) eq 'ARRAY') { 
			push @recipients,  map { 
				ref($_) eq 'ARRAY' ? $_->[0] : $_
			} @$to;
		} else { 
			push @recipients, $to;
		}
	}
	if(my $to = $opt->{cc}) { 
		if(ref($to) eq 'ARRAY') { 
			push @recipients,  map { 
				ref($_) eq 'ARRAY' ? $_->[0] : $_
			} @$to;
		} else { 
			push @recipients, $to;
		}
	}
	if(!@recipients) { 
		die("No recipients");
	} 
	my @ok_addrs = $smtp->recipient(@recipients, { Notify => ['FAILURE','DELAY'], SkipBad => 1 }) ;
	my %ok_addrs = map { $_=>1 } @ok_addrs;
	my @bad_addrs = grep { ! $ok_addrs{$_} } @recipients;
	if(@bad_addrs) { 
		warn "Addresses ".join(', ', @bad_addrs)." are bad";
	}
	if(!@ok_addrs) { 
		return;
	}
	$smtp->data(Encode::encode_utf8($message->as_string));
	warn "Result: ".$smtp->message;
	$smtp->quit;
	
}
1;