use strict;
use Test;
BEGIN { plan tests => 1}
### use WWW::Easy; # cannot use without apache
use WWW::Easy::ORMAPI;
use WWW::Easy::Auth;
use WWW::Easy::Mail;
use WWW::Easy::Config;
use WWW::Easy::AnyEventPg;
use WWW::Easy::Daemon;
use WWW::Easy::Pg;
use WWW::Easy::AnyEvent;
use WWW::Easy::DateUtil;
use WWW::Easy::SPI;
use WWW::Easy::HTML2PDF;

ok ( 1 );
