package WWW::Easy::HTML2PDF;
use strict;
use IPC::Run qw(run);

my ($FONTPATH, $CONVERTER);

sub init_converter { 
	return $CONVERTER if $CONVERTER;
	foreach (qw(/usr/local/bin/wkhtmltopdf /usr/local/bin/run_wkhtmltopdf /usr/bin/wkhtmltopdf /usr/local/bin/wkhtmltopdf)) {
		if (-f $_) {
			$CONVERTER = $_;
			last;
		}
	} 

  # проверяем установлены ли в системе шрифты. если нет - нет особого
  # смысла генерить уродливый pdf.
	foreach (qw(/usr/share/fonts/truetype/msttcorefonts
              /usr/share/fonts/msttcore)) {
	    if (-f "$_/times.ttf") {
			$FONTPATH = $_; 
			last;
	    }
	}
	die 'Not found fonts' unless $FONTPATH;
	die 'Not found converter(wkhtmltopdf)' unless $CONVERTER;	
	return $CONVERTER;
}

sub html2pdf { 
	my ($html, $pdf, %opt)= @_;
	my $err;
	my $converter = $opt{converter} || init_converter();
	my @add_options;
	if(my $m = $opt{margins}) { 
		push @add_options, "-T", $m->[0], "-R", $m->[1], "-B", $m->[2], "-L", $m->[3];
	}
	if(my $m = $opt{page_numbers}) { # left,right or center
		push @add_options, "--footer-$m",'[page]/[topage]';
	}
	run [$converter, ($opt{with_js} ? ( '--enable-javascript', '--javascript-delay','10000', '--no-stop-slow-scripts') : ()), @add_options,
		 '-q', '-', '-'], $html, $pdf, \$err
  		 or die "cat returned $? stderr was: $err";
	if(ref($pdf)) { 
		$$pdf =~ s/^.*?%PDF/%PDF/s;
	}
}

1;
