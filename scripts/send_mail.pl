#!/usr/bin/perl
use strict;
use WWW::Easy::Mail;
use Term::ReadKey;
use Getopt::Long;

GetOptions ("smtp=s" =>\my $smtp, "user=s" => \my $smtp_user, "to=s" => \my $to, "recipient=s" =>\my $to_text,
	"from=s" => \my $from, "sender=s"=>\my $from_text, "subject=s"=>\my $subject, "text=s"=>\my $text, help=>\my $help,
);
if($help) { 
	die "Usage : $0 --smtp=host:port --user=smtpUserName --to=x\@y.com --recipient=\"Name Name\" 
             --from=my\@addr --sender=\"My Name\" --subject=\"The Subject\" --text=\"The text\n";
}

my ($smtp_server, $smtp_port ) = split(/:/, $smtp);
$smtp_port ||= 495;

my $smtp_password = $ENV{smtp_password};
unless ($smtp_password) {

	print "Enter your password: ";
	ReadMode 'noecho';
	$smtp_password = ReadLine 0;
	chomp $smtp_password;
	ReadMode 'normal';
	print "\n";
}



WWW::Easy::Mail::send(
	mail_client=>{
		mailer=>'SMTP',
		mailer_args=> {
			host     => $smtp_server,
			port     => $smtp_port,
			username => $smtp_user,
			password => $smtp_password,
			ssl      => 1,
		}
	},
	to       => [[$to, $to_text]],
	from     => [$from, $from_text],
	subject  => $subject,
	text     => $text

);
