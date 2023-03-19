package WWW::Easy::Config;
use strict;
use File::Slurp;
use JSON::XS;

sub read_config { 
    my $config_file = shift;
    -f $config_file or die("Config file $config_file doesn't exist");
    -r $config_file or die("Config file $config_file is not readable");
    return decode_json(File::Slurp::read_file($config_file) || die("Config file $config_file empty"));
}

1;
