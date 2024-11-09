use strict;
use Test;
BEGIN { plan tests => 1}
use WWW::Easy::DateUtil;


ok ( WWW::Easy::DateUtil::add_days('2020-03-09', 115) , '2020-07-02' );







