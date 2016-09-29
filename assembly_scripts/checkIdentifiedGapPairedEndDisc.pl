#!/usr/bin/perl
# This script processes the tab delimited output from identifyFilledGaps.pl, a bam file containing paired end read alignments to the target assembly
# and generates a score for gap filling based on soft clipping and discordant read mappings
# OUTPUT:
# Class gap_name gap_length close_coordinates close_len read_num covered_bases regions_of_conflict
#
# class can be: "FullClose, CrypticMis, GAP, Unknown"
# version 2: used a depth instead of a raw alignment check strategy

use strict;
use Getopt::Std;

my %opts;
my $usage = "perl $0 -g <tab delimited gap closure file> -t <target reference bam file> -o <output tab file summary>\n";

getopt('gto', \%opts);

unless(defined($opts{'g'}) && defined($opts{'t'}) && defined($opts{'o'})){
	print $usage;
	exit;
}

unless( -s $opts{'t'} && -s "$opts{t}.bai"){
	print "Error! Bam file either doesn't exist or isn't indexed by samtools!\n";
	exit;
}

my $tested = 0; my $skipped = 0;
my %data; # {gap name} ->[gap_len, close_coordinates, close_len, sumdepth, conflict_bases, conflict_str]
my %gapCoords; # {close chr} -> [] -> [start, end]

open(my $IN, "< $opts{g}") || die "Could not open gap closure file!\n";
open(my $BED, "> temp.bed");
while(my $line = <$IN>){
	chomp $line;
	my @segs = split(/\t/, $line);
	my $gapname = "$segs[1]:$segs[2]-$segs[3]";
	my $gaplen = $segs[3] - $segs[2];
	my ($alignc1, $aligns1, $aligne1) = convert_ucsc($segs[6]);
	my ($alignc2, $aligns2, $aligne2) = convert_ucsc($segs[7]);
	if($segs[0] eq "Closed"){
		my ($tstart, $tend) = get_coords($aligns1, $aligns2, $aligne1, $aligne2);
		my $closecoords = "$segs[5]:$tstart-$tend";
		my $closelen = $tend - $tstart;
		$data{$gapname} = [$gaplen, $closecoords, $closelen, 0, 0, ""];
		print {$BED} "$segs[5]\t$tstart\t$tend\t$gapname\n";
		$tested++;
	}else{
		$skipped++;
	}
}
close $BED;
close $IN;

my $depth = process_bam_depth_file($opts{'t'}, "temp.bed", \%data, \%gapCoords, 5);

open(my $OUT, "> $opts{o}");
foreach my $gaps (sort {$a cmp $b} keys(%{$depth})){
	my @datarray = @{$depth->{$gaps}};
	my @carray; 
	my $type = "FullClose";
	if($datarray[4] > 0){
		$type = "GAP";
		my @cons = split(/;/, $datarray[5]);
		my $first = $cons[0]; $current = $cons[0];
		for(my $x = 1; $x < scalar(@cons); $x++){
			if($cons[$x] = $current + 1){
				$current = $cons[$x];
			}else{
				if($first == $current){
					push(@carray, $first);
				}else{
					push(@carray, "$first-$current");
				}
				$first = $cons[$x]; $current = $cons[$x];
			}
		}
	}
	my $cstr = join(";",@carray);
	print {$OUT} "$type\t$gaps\t$datarray[0]\t$datarray[1]\t$datarray[2]\t$datarray[3]\t$datarray[4]";
	if($datarray[4] > 0){
		print {$OUT} "\t$cstr\n";
	}else{
		print {$OUT} "\n";
	}
}
close $OUT;

print "\n";
close $IN;
close $OUT;

print "Tested: $tested\n";
print "Skipped: $skipped\n";
		
exit;
# {gap name} ->[gap_len, close_coordinates, close_len, sumdepth, conflict_bases, conflict_str]
sub process_bam_depth_file{
	my ($bam, $bed, $data, $gapCoords, $mincov) = @_;
	open(my $BAM, "samtools depth -b $bed -q 30 -Q 40 $bam |");
	my $lastchr = "NA"; my $lastend = 0; my $gapname; 
	while(my $line = <$BAM>){
		chomp $line; 
		my @segs = split(/\t/, $line);
		
		# Check to see if we need to update the gapname
		if($segs[0] ne $lastchr || $segs[1] > $lastend){
			# Find out which gap region we're dealing with		
			foreach my $row ($gapCoords->{$segs[0]}){
				if($segs[1] <= $row->[1] && $segs[1] >= $row->[0]){
					$gapname = "$segs[0]:" . $row->[0] . "-" . $row->[1];
					$lastchr = $segs[0];
					$lastend = $row->[1];
					last;
				}
			}
		}
		
		if($segs[2] < $mincov){
			$data->{$gapname}->[4] += 1;
			$data->{$gapname}->[5] .= "$segs[1];";
		}
		
		$data->{$gapname}->[3] += $segs[2];
	}
	close $BAM;
	return $data;
}

sub process_bam_file{
	my ($bam, $chr, $start, $end) = @_;
	my $reads = 0; my $sclip = 0; my $oae = 0;
	open(my $BAM, "samtools depth -r $chr:$start-$end -q 30 -Q 40 $bam  |");
	while(my $sam = <$BAM>){
		chomp $sam;
		my @segs = split(/\t/, $sam);
		# check if this is a oae
		if($segs[6] eq "*"){
			$oae++;
		}
		
		# process cigar looking for a count of softclipped bases
		while($segs[5] =~ m/(\d+)(\D{1})/g){
			my $cnum = $1;
			my $cstr = $2;
			if($cstr eq "H" || $cstr eq "S"){
				$sclip += $cnum;
			}
		}
		$reads++;
	}
	close $BAM;
	return $reads, $sclip, $oae;
}

sub convert_ucsc{
	my ($ucsc) = @_;
	my @segs = split(/[:-]/, $ucsc);
	return $segs[0], $segs[1], $segs[2];
}

sub get_coords{
	my (@positions) = @_;
	@positions = sort {$a <=> $b} @positions;
	return $positions[1], $positions[2];
}