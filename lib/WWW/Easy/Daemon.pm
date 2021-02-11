package WWW::Easy::Daemon;
use strict;
use Proc::PID::File;
use Sys::Syslog;
use File::Slurp;
use Net::Server::Daemonize;
use JSON::XS;
use Devel::StackTrace;
use Pod::Usage;

our @ISA    = qw(Exporter);
our @EXPORT = qw(start_script read_config pod2usage daemonize easy_try);
######################## некие полезные функции для скриптов
sub start_script { 
    if ( my $pid = Proc::PID::File->running({dir=>'/tmp', verify=>1}) ) {
        die '$0 already running, pid='.$pid;
    } 

    openlog($0, "perror,pid,ndelay", "local0");    # don't forget this

    $SIG{__WARN__} = sub { 
        syslog('info', join(' ', @_));
    };

    $SIG{__DIE__} = sub { 
        syslog('crit', join(' ', @_));
        exit(1);
    };
}
sub daemonize { 
    my ($name, $user, $group, $logdir) = @_;
    my $pidfile = "/tmp/$name.pid";
    if($ARGV[0] eq 'stop' || $ARGV[0] eq 'restart') { 
        my $pid = (-f $pidfile) ? File::Slurp::read_file($pidfile) : undef;
        if($pid) { 
            chomp($pid);
            warn "Killing $pid with TERM\n";
            kill TERM => $pid;
            foreach my $i (0..15) { 
                sleep 1;
                last unless -d "/proc/$pid";
            }
            if(-d "/proc/$pid") { 
                die "Process did not exist\n";
            }
        }
        if($ARGV[0] eq 'stop') { 
            exit(0);    
        }
    }

	my $log;
	my $logfile;
	if($logdir) { 
		$logfile = "$logdir/$name.log";
		open($log, '>>', $logfile) || die("Cannot open $logfile: $!");
		select $log; $|=1;
	} else { 
		openlog($name, "perror,pid,ndelay", "local0");    # don't forget this
	}

	my $dolog = sub {
		if($logdir) { 
	        my @t=localtime(time);
        	my $str = join(' ', @_);
    	    if($str !~ /\n$/) { $str.="\n"; }
	        print $log sprintf("[%04d-%02d-%02d %02d:%02d:%02d][$$] ", $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]).$str;
		} else { 
			syslog('info', join(' ', @_));
		}
    };

    $SIG{__WARN__} = $dolog;

    $SIG{__DIE__} = sub { 
		if($logdir) { 
			$dolog->(@_);
		} else { 
	        syslog('crit', join(' ', @_));
    	    syslog('crit', 'at '.Devel::StackTrace->new()->as_string);
		}
		exit(1);
    };

	$user  ||= 'nobody';
	$group ||= 'nogroup';

### start Net::Server::Daemonize::daemonize remake

    Net::Server::Daemonize::check_pid_file($pidfile) if defined $pidfile;

    my $uid = Net::Server::Daemonize::get_uid($user);
    my $gid = Net::Server::Daemonize::get_gid($group); # returns list of groups
    my $pid = Net::Server::Daemonize::safe_fork();
    exit(0) if $pid; # exit parent

    # child
    Net::Server::Daemonize::create_pid_file($pidfile) if defined $pidfile;

	my $gid0 = (split(/\s+/, $gid))[0];
    chown($uid, $gid0, $pidfile) if defined $pidfile;

    Net::Server::Daemonize::set_user($uid, $gid);

    open STDIN,  '<', '/dev/null' or die "Can't open STDIN from /dev/null: [$!]\n";
    open STDOUT, '>', '/dev/null' or die "Can't open STDOUT to /dev/null: [$!]\n";
    open STDERR, '>&STDOUT'       or die "Can't open STDERR to STDOUT: [$!]\n";

    ### does this mean to be chroot ?
    chdir '/' or die "Can't chdir to \"/\": [$!]";

    POSIX::setsid(); # Turn process into session leader, and ensure no controlling terminal

    ### install a signal handler to make sure SIGINT's remove our pid_file
    $SIG{'INT'}  = sub { HUNTSMAN($pidfile) } if defined $pidfile;

### end et::Server::Daemonize::daemonize remake

	if($logdir) { 
    	open(STDOUT, '>>', $logfile) || die("Cannot open $logfile: $!");  # "Daemonize" redirects stderr to stdout and stdout to /dev/null
		open(STDERR, '>>', $logfile) || die("Cannot open $logfile: $!");  # "Daemonize" redirects stderr to stdout and stdout to /dev/null
	}
}

sub read_config { 
    my $config_file = shift;
    -f $config_file or pod2usage (-msg=>"Config file $config_file doesn't exist");
    -r $config_file or pod2usage (-msg=>"Config file $config_file is not readable");

    return decode_json(File::Slurp::read_file($config_file) || pod2usage(-msg=>"Config file $config_file empty"));
}

sub easy_try(&) {
	my $func = shift;
	local $SIG{__DIE__} = undef;
	if(wantarray) { 
		my @f = eval { &$func; } ;
		return @f;
	} else { 
		my $f = eval { &$func; } ;
		return $f;
	}
}

1;
