#!/usr/bin/perl
# This script is designed to find frequent transchr events that are likely to indicate repeats rather than transchr

use strict;
use Getopt::Std;
use Class::Struct;
use kentBinTools;

struct('bed' => {
	chr => '%',
});

struct('binbed' => {
	bin => '%',
});

struct('simpbed' => {
	start => '$',
	end => '$',
	name => '$',
});

my $usage = "perl $0 -d <input file transchr bedpe> -f <Repeats bed file> -o <output bed file>\n";
my %opts;

getopt('dof', \%opts);

unless(defined($opts{'d'}) && defined($opts{'f'}) && defined($opts{'o'})){
	print $usage;
	exit;
}

my $binner = kentBinTools->new();
my $beds = bed->new();
my @transchr;

# load filters

open(IN, "< $opts{f}") || die "Could not open repeat bed file!\n";
while(my $line = <IN>){
	chomp $line;
	my @segs = split(/\t/, $line);
	
	my $bin = $binner->getbin($segs[1], $segs[2]);
	if(!exists($beds->chr()->{$segs[0]})){
		$beds->chr($segs[0], binbed->new());
	}
	if(!exists($beds->chr($segs[0])->bin()->{$bin})){
		$beds->chr($segs[0])->bin($bin, []);
	}
	push(@{$beds->chr($segs[0])->bin()->{$bin}}, simpbed->new('start' => $segs[1], 'end' => $segs[2], 'name' => $segs[3]));
}

close IN;

print STDERR "Done with repeats file loading\n";

my $linenum = 0;
my %binstore;
open(COMP, "> comp.bed");

# Now process transchr file to remove entries that overlap likely repeats
open(IN, "< $opts{d}") || die "Could not open input file!\n";
open(OUT, "> $opts{o}");
while(my $line = <IN>){
	chomp $line;
	my @segs = split(/\t/, $line);
	
	my @searchbins1 = $binner->searchbins($segs[1], $segs[2]);
	my @searchbins2 = $binner->searchbins($segs[4], $segs[5]);
	
	my $found1 = 0;
	my $found2 = 0;
	my %names; 
	foreach my $b (@searchbins1){
		if(!exists($beds->chr($segs[0])->bin()->{$b})){next;}
		foreach my $bed (@{$beds->chr($segs[0])->bin()->{$b}}){
			if($binner->overlap($segs[1], $segs[2], $bed->start(), $bed->end()) > 1){
				$found1 = 1;
				$names{$bed->name()} = 1;
			}
		}
	}
	
	foreach my $b (@searchbins2){
		if(!exists($beds->chr($segs[0])->bin()->{$b})){next;}
		foreach my $bed (@{$beds->chr($segs[3])->bin()->{$b}}){
			if($binner->overlap($segs[4], $segs[5], $bed->start(), $bed->end()) > 1){
				$found2 = 1;
				$names{$bed->name()} = 1;
			}
		}
	}
	
	if(!(!$found1 && !$found2) && ($found1 || $found2) && !($found1 && $found2) && scalar(keys(%names)) <= 1 && $segs[6] > 2){
		# We need to find the end that did not match the repeat
		my $tchr = ($found1)? $segs[0] : $segs[3];
		my $tstart = ($found1)? $segs[4] : $segs[1];
		my $tend = ($found1)? $segs[5] : $segs[2];
		my @bins = ($found1)? @searchbins2 : @searchbins1;
		my @names = keys(%names);
		
		my $fchr = ($found1)? $segs[3] : $segs[0];
		my $fstart = ($found1)? $segs[1] : $segs[4];
		my $fend = ($found1)? $segs[2] : $segs[5];
		
		foreach my $b (@bins){
			$binstore{$tchr}->{$b} = 1;
		}
		
		print COMP "$segs[0]\t$tstart\t$tend\t$fchr:$fstart-$fend;$segs[6]\n";
		
		
		
		
		#system("rm comp.bed tmp.bed");
	}
	$linenum++;
	if($linenum % 10000 == 0){
		print STDERR "$linenum\r";
	}
}
print STDERR "\n";

foreach my $chr (keys(%binstore)){
	my @keys = keys(%{$binstore{$chr}});
	createBedTempFile("tmp.bed", "test", $chr, \@keys, $beds);
}
close COMP;

open(BED, "closestBed -a comp.bed -b tmp.bed -d |") || die "Could not use closestBed on data!\n";
while(my $l = <BED>){
	chomp $l;
	my @bsegs = split(/\t/, $l);
	if($bsegs[-1] >= 1000){
		# In this case, the repeat is too far away from the anchor read to have been there
		# before.
		print OUT join("\t", @bsegs) . "\n";
	}		
}
close BED;

close OUT;
close IN;

exit;

# Given the name of a repeat, print out only the repeat bed coords within the bins that have the given name
sub createBedTempFile{
	my ($tmpfile, $repeat, $chr, $bins, $beds) = @_;
	
	my @store;
	foreach my $b (@{$bins}){
		if(!exists($beds->chr($chr)->bin()->{$b})){next;}
		foreach my $bed (@{$beds->chr($chr)->bin()->{$b}}){
			#if($bed->name eq $repeat){
				push(@store, [$chr, $bed->start, $bed->end, $bed->name]);
			#}
		}
	}
	@store = sort{$a->[1] <=> $b->[1]} @store;
	
	open(TMP, ">> $tmpfile");
	foreach my $s (@store){
		print TMP join("\t", @{$s}) . "\n";
	}
	close TMP;
}