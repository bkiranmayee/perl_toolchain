#!/usr/bin/perl
# This script takes an annotated bcf file (with index) and converts it into a tab delimited format for easy referencing
# This is the STDIN version of the script that is designed to work with preprocessed filtering

use strict;


#CHROM  POS     ID      REF     ALT    QUAL     FILTER  INFO    FORMAT  BIBR02.1        BIBR03.1        
#open(IN, "bcftools view $opts{b} $opts{r} |") || die "Could not open bcftools output!\n $usage";
#my @header;
while(my $line = <STDIN>){
	if($line =~ /^##/){next;}
	elsif($line =~/^#CHROM/){
		chomp $line;
		my @segs = split(/\s+/, $line);
		#push(@header, ("CHR", $segs[1], $segs[3], $segs[4], $segs[5], "MUTATION", "PRIORITY", "GENE"));
		#push(@header, @segs[9 .. $#segs]);
		print "CHR\t$segs[1]\t$segs[3]\t$segs[4]\t$segs[5]\tTYPE\tMUTATION\tPRIORITY\tGENE\tAA\t";
		print  join("\t", @segs[9 .. $#segs]) . "\n";
	}else{
		chomp $line;
		my @segs = split(/\t/, $line);
		print  "$segs[0]\t$segs[1]\t$segs[3]\t$segs[4]\t$segs[5]\t";
		#INDEL;IS=4,1.000000;DP=84;VDB=1.008941e-02;AF1=0.9542;AC1=138;DP4=2,2,52,8;MQ=28;FQ=-8.94;PV4=0.11,1,0.19,1;EFF=INTERGENIC(MODIFIER||||||||||1)
		my @infosegs = split(/;/, $segs[7]);
		if($infosegs[0] eq "INDEL"){
			print  "INDEL";
		}else{
			print  "SNP";
		}
		
		#EFF=SYNONYMOUS_CODING(LOW|SILENT|acG/acA|T334|581|PRLR|protein_coding|CODING|ENSBTAT00000014437|9|1)
		my @annosegs = split(/,/, $infosegs[-1]);
		my @mutation;
		my @priority;
		my @gene;
		my @aas;
		my ($m, $p, $g, $aa);
		foreach my $a (@annosegs){
			$a =~ s/EFF=//g;
			($m) = $a =~ /(.+)\(.*\)/;
			my ($str) = $a =~ /.+\((.*)\)/;
			my @effsegs = split(/\|/, $str);
			$p = $effsegs[0];
			$g = $effsegs[5];
			$aa = $effsegs[3];
			push(@aas, $aa);
			push(@mutation, $m);
			push(@priority, $p);
			push(@gene, $g);
		}
		
		print  "\t" . join(';', @mutation) . "\t" . join(';', @priority) . "\t" . join(';', @gene) . "\t" . join(';', @aas);
		
		for(my $x = 9; $x < scalar(@segs); $x++){
			my @forsegs = split(/:/, $segs[$x]);
			my @gsegs = split(/[\/\|]/, $forsegs[0]);
			
			print  "\t" . join(';', @gsegs);
		}
		print  "\n";
	}
}
#close IN;

exit;