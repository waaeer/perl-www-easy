use strict;
use WWW::Easy::Mail;
use Test::More;
use MIME::Parser;
use Encode;
use utf8;

plan tests => 2; 

open(TMP, ">/tmp/test.pdf") || die("Cannot write a test pdf file: $!"); 
print TMP "%PDF-1.5\n%\n1 0 obj\n";
close TMP;

{ package WWW::Easy::Mail::debug;
  our $var;
  sub new { 
  	return bless {}, shift;
  } 
  sub send { 
  	my ($self, $message, $opt) = @_;
  	$var = $message->as_string;
  }
}

WWW::Easy::Mail::send (
	mail_client => { mailer => 'debug' },
	to     => [[ 'ivanov@ivanov.kom',  "Иванов"]],
	cc     => [[ 'petrov@ivanov.kom',  "Петров"],[ 'sidorov@ivanov.kom', "Сидоров"]],
	from   => [  'robotov@ivanov.kom', "Робот"  ],
	subject => "Сабджект письма",
	text    => "Текст письма",
	attachment => [ "/tmp/test.pdf" ]
);

#print $WWW::Easy::Mail::debug::var;

my $parser = MIME::Parser->new();   
$parser->output_dir("/tmp");
$parser->output_prefix("easym_");
$parser->decode_headers(1);

my $msg = $parser->parse_data($WWW::Easy::Mail::debug::var);
#print $msg->dump_skeleton;
is(Encode::decode_utf8($msg->head->get('Subject')),"Сабджект письма\n", "subject match");

my $file =  ($msg->parts())[1];	

is($file->head->get('Content-type'),"application/pdf; name=\"test.pdf\"\n", "pdf file type");




unlink "/tmp/test.pdf";
