#!/usr/bin/perl
# This is a script designed to process a filtered Samtools vcf and estimate MapQ values before and after each variant position within a 36 bp window
# The basis of this selection is to identify candidate markers with sufficient mappability to be used in SNP probe generation
# Output format is: SNP ID <tab> chr <tab> pos <tab> ref allele <tab> alt allele <tab> upstream MapQ <tab> downstream MapQ <tab> 

use strict;
use Getopt::Std;

my %opts;
my $usage = "perl $0 -v <bed file of filtered variant sites> -l <list of SNP IDs to keep from the VCF> -m <mpileup bed file with variant sites> -o <output>\n";

getopt('vlmo', \%opts);

unless(defined($opts{'v'}) && defined($opts{'l'}) && defined($opts{'m'}) && defined($opts{'o'})){
	print $usage;
	exit;
}

# generate flat set of markers to keep
my %keep;
open(my $IN, "< $opts{l}") || die "Could not open file: $opts{l}!\n";
while(my $line = <$IN>){
	chomp $line;
	$keep{$line} = 1;
}
close $IN;

my %markers; #{chrom} -> {pos} = [end, markerID, [later 5' mapq], [later 3' mapq]]
# Filter VCF and keep markers in a list
open(my $IN, "< $opts{v}");
while(my $line = <$IN>){
	if($line =~ /^#/){next;}
	chomp $line;
	my @segs = split(/\t/, $line);
	#if(exists($keep{$segs[2]})){
		#push(@markers, [$segs[0], $segs[1], $segs[2], $segs[3]]);
	#}
	$markers{$segs[0]}->{$segs[1]} = [$segs[2], $segs[3]];
}
close $IN;

# sort them in order of chrom and position
#@markers = sort{ $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1]} @markers;

print STDERR "Loaded VCF kept markers!\n";

# now, loop through the mpileup data 73 lines at a time
open(my $IN, "< $opts{m}") || die "Could not open mpileup bed file: $opts{m}\n";
my @rows; # 73 line buffer
for(my $x = 0; $x < 73; $x++){
	my $line = <$IN>; 
	chomp $line; 
	my @segs = split(/\t/, $line);
	push(@rows, [@segs]);
}

# find out the coordinates that are spanned here
#my $markerIdx = 0;
my @coords = gatherPositions(\@rows);
for(my $x = 0; $x < 37; $x++){
	my ($chr, $pos) = split(/:/, $coords[$x]);
	
	#my $curM = $markers{$chr}->{$pos}
	#if($chr ne $curM->[0]){
	#	for(my $y = 0; $y < scalar(@markers); $y++){
	#		if($markers[$y]->[0] eq $chr){
	#			$markerIdx = $y;
	#			last;
	#		}
	#	}
	#}
	#if($chr eq $curM->[0] && $pos == $curM->[1]){
	if(exists($markers{$chr}->{$pos})){
		my ($avg5, $avg3) = getSumMapQ(\@rows, $x, $chr, $pos);
		push(@{$markers{$chr}->{$pos}},  $avg5);
		push(@{$markers{$chr}->{$pos}}, $avg3);
		#$markerIdx++;
	}
	#elsif($chr eq $curM->[0] && $pos > $curM->[1]){
	#	$curM->[4] = 0;
	#	$curM->[5] = 0;
	#	$markerIdx++;
	#}
}

# Main loop to go through the file
while(my $line = <$IN>){
	chomp $line;
	my @segs = split(/\t/, $line);
	shift(@rows);
	push(@rows, [@segs]);
	
	my $chr = $rows[35]->[0];
	my $pos = $rows[35]->[1];
	#my $curM = $markers[$markerIdx];
	if(exists($markers{$rows[35]->[0]}->{$rows[35]->[1]})){
		my ($avg5, $avg3) = getSumMapQ(\@rows, 35, $rows[35]->[0], $rows[35]->[0]);
		push(@{$markers{$chr}->{$pos}},  $avg5);
		push(@{$markers{$chr}->{$pos}}, $avg3);
	}
	#elsif($rows[35]->[0] eq $curM->[0] && $rows[35]->[1] > $curM->[1]){
	#	$curM->[4] = 0;
	#	$curM->[5] = 0;
	#	$markerIdx++;
	#}elsif($rows[35]->[0] ne $curM->[0]){
	#	for(my $y = 0; $y < scalar(@markers); $y++){
			# search for chr start location
	#		if($markers[$y]->[0] eq $rows[35]->[0]){
	#			$markerIdx = $y;
	#			last;
	#		}
	#	}
	#}
	
}

close $IN;

# Write output
print STDERR "Writing output to $opts{o}\n";
open(my $OUT, "> $opts{o}");
foreach my $chr (sort {$a cmp $b} keys(%markers)){
	foreach my $pos (sort {$a <=> $b} keys(%{$markers{$chr}})){
		if(scalar(@{$markers{$chr}->{$pos}}) < 3){
			push(@{$markers{$chr}->{$pos}}, -1, -1);
		}
		print {$OUT} "$chr\t$pos\t" . join("\t", @{$markers{$chr}->{$pos}}) . "\n";
	}
}
close $OUT;

exit;

# sums the MapQ scores for each mapped read in the region
sub getSumMapQ{
	my ($aref, $varIdx, $varChr, $varPos) = @_;
	my $avg5 = 0; my $avg3 = 0;
	my $sum5 = 0; my $c5 = 0;
	for(my $x = 0; $x < $varIdx; $x++){
		$sum5 += $aref->[$x]->[3];
		$c5++;
	}
	
	$avg5 = ($c5 > 0)? $sum5 / $c5 : 0;
	
	my $sum3 = 0; my $c3 = 0;
	for(my $x = $varIdx +1; $x < scalar(@{$aref}); $x++){
		$sum3 += $aref->[$x]->[3];
		$c3++;
	}
	
	$avg3 = ($c3 > 0)? $sum3 / $c3 : 0;
	return $avg5, $avg3;
}

sub getSumScore{
	my ($aref) = @_;
	my $sum = 0; my $count = 0;
	for(my $y = 7; $y < scalar(@{$aref}); $y += 5){
		if($aref->[$y] ne "*"){
			my @bsegs = split(/,/, $aref->[$y]);
			foreach my $j (@bsegs){
				$count++;
				$sum += $j;
			}
		}
	}
	return $sum, $count;
}

# returns an array of chrs and positions from the list
sub gatherPositions{
	my ($aref) = @_;
	my @data;
	foreach my $r (@{$aref}){
		my @rsegs = @{$r};
		push(@data, "$rsegs[0]:$rsegs[1]");
	}
	return @data;
}
