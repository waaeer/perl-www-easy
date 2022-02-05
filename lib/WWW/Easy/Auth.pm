package WWW::Easy::Auth;
use Digest::MD5;
use Encode;
use strict;

sub _make_token_key {
        my ($user_id, $time, $ipaddr, $secret) = @_;
        my $network = substr(join('', map {sprintf('%08b', $_)} split(/\./, $ipaddr)), 0, 20);
        return Digest::MD5::md5_base64(join('+', $secret, $time, $user_id, $network));
}

sub _check_token {
        my ($name, $token, $ipaddr, $ttl, $secret) = @_;
        return undef if $token eq 'no';
		if (utf8::is_utf8($token)) { $token = Encode::encode_utf8($token); }
		$token =~ s/%(\w\w)/chr(hex($1))/gsex;
        my ($key, $user_id, $time) = split('!', $token);
        my $now = time();
        if ($time > $now) {
            warn "[AUTH \"$name\"][IP $ipaddr] check_token error:  Suspect fake cookie: the time set in cookie is in future. Now: $now, cookie time: $time.";
            return undef;
        }
        my $key_should_be = _make_token_key($user_id, $time, $ipaddr, $secret);
        if ($key eq $key_should_be) {
            if ($ttl && ($now - $time) > $ttl ) {
                warn "[AUTH \"$name\"][IP $ipaddr] check_token error: Cookie $token expired: time=$time; now=$now";
                return undef;
            }
            return $user_id;
        }
		warn "[AUTH \"$name\"][IP $ipaddr] check_token error: '$key' ne '$key_should_be'";
        return undef;
}        


1;
