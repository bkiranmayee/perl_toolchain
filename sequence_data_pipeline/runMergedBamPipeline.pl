#!/usr/bin/perl
# This is a combination of four scripts: bamMergeUtility.pl, samtoolsSNPFork.pl, getBamStats.pl and 
# bwaFQFork.pl. It also adds in a SNPEff automation for the vcf. It generates a large merged, indexed
# bam, and an annotated VCF of SNPs and INDELs.
# Spreadsheet columns:
# 	fq1\tfq2\tlibraryname\tanimalname
# 9/8/2015  -- Version 0.0.2: 	Added  javaArg required config key to tune JVM runtime parameters
#				Also Added STDERR logger
# 3/22/2016 -- Version 0.0.3: 	Added advanced help and config file carriage return compability

use strict;
use Getopt::Long;
use File::Basename;
use bamTools;
use Forks::Super;
use simpleConfigParser;
use simpleLogger;
use fastqcParser;
use IPC::Open3;
use IO::File;
#use threads;
#use threads::shared;
#use threadPool;

my ($configfile, $javaexe, $javaarg, $picardfolder, $outputfolder, $snpeffjar, $spreadsheet, $refgenome, $threads, $fastacoords, $fastqc);
my ($runSNPFork, $runSNPEff, $runFQC);
my @requiredConfig = ("java", "picard", "snpeff", "fastqc", "runSNP", "runEFF", "runFQC", "javaArg");
my $scriptdir = dirname(__FILE__);

my $usage = "perl $0 --fastqs <spreadsheet to be processed> --output <base output folder> --reference <reference genome fasta>
Version 0.0.3
Arguments:
	--fastqs	A tab-delimited spreadsheet with fastq file locations and read group info
	--output	The base output folder for all bams and vcfs
	--reference	The reference genome fasta file

Optional:
	--config	Override default configuration (searches for ~/.mergedpipeline.cnfg by default)
	--coords	Reference genome fasta coordinates for threaded SNP calling
	--threads	Number of threads to fork (default: 1)
	--help		Advanced help menu (overrides all other commands);
	";

$configfile = "$ENV{HOME}/.mergedpipeline.cnfg";
$threads = 1;
my $advhelp = 0;
	
GetOptions("config=s" => \$configfile,
	"fastqs=s" => \$spreadsheet,
	"output=s" => \$outputfolder,
	"reference=s" => \$refgenome,
	"coords=s" => \$fastacoords, 
	"threads=i" => \$threads, 
	"help" => \$advhelp);

if($advhelp){
	printAdvancedHelp();
}
	
if(!defined($spreadsheet) || !defined($outputfolder)){
	print $usage;
	exit;
}

# Parse configuration
my $cfg = simpleConfigParser->new();
$cfg->loadConfigFile($configfile);
$cfg->checkReqKeys(\@requiredConfig);


# Population config settings
$picardfolder = $cfg->getKey("picard");
$fastqc = $cfg->getKey("fastqc");
$javaexe = $cfg->getKey("java");
$javaarg = $cfg->getKey("javaArg");
$snpeffjar = $cfg->getKey("snpeff");
$runFQC = $cfg->getKey("runFQC");
$runSNPEff = $cfg->getKey("runEFF");
$runSNPFork = $cfg->getKey("runSNP");

foreach my $prog ("bwa", "samtools", "vcfutils.pl", "bcftools"){
	StaticUtils::checkReqs($prog);
}

if(! -d $outputfolder){
	mkdir($outputfolder) || die "Could not create base output folder: $outputfolder!\n";
}

# Generate log file and error file
my $log = simpleLogger->new('logFileBaseStr' => 'MergedBamPipeline');
my $errorlog = simpleLogger->new('logFileBaseStr' => 'MergedBamPipeline.err');

$log->OpenLogger($outputfolder);
$log->Info("Start", "Began pipeline run for spreadsheet: $spreadsheet in $outputfolder using $threads threads");

$log->Info("Start", "Using config file: $configfile");
$log->Info("Start", "Exes: picard-$picardfolder fastqc-$fastqc java-$javaexe javaArg-$javaarg snpeff-$snpeffjar");
$log->Info("Start", "Run Settings: runFQC-$runFQC runSNPEFF-$runSNPEff runSNPFork-$runSNPFork");

$errorlog->OpenLogger($outputfolder);

# Check the reference genome and see if it has been indexed yet by samtools. If not, do that indexing
my $reffai = "$refgenome.fai";
unless(-e $reffai){
	$log->Warn("RefIndexer", "Samtools fasta index not found! Generating it now.");
	system("samtools index $refgenome");
}

$log->Info("SpreadSheet", "Starting fastq file processing.");
# Load spreadsheet for processing
open(IN, "< $spreadsheet") || die "could not open fastq spreadsheet: $spreadsheet!\n";
my %counter;
my %bams; # {sample} -> [] -> sortedbam
my @parsers;
my $alignthreads = ($runFQC)? int($threads / 3) : $threads; # If we are running fastqc at the same time, then only run one alignment thread per fastqc thread, rounded down
my $fqcThreads = int(($threads / 3) * 2);

# Ensure that we don't have fractional threads!
if($alignthreads < 1){
	$alignthreads = 1;
}
if($fqcThreads < 1){
	$fqcThreads = 1;
}

my $spreadsheetBase = basename($spreadsheet);
my $fqcSpreadsheet = "$outputfolder/$spreadsheetBase.fastqc";
if($runFQC){
	my @headers = fastqcParser->getHeaderArray(); 
	open(OUT, "> $fqcSpreadsheet") || $log->Fatal("[Main]", "Could not create fastqc Spreadsheet: $outputfolder/$spreadsheetBase.fastqc\n");
	print OUT join("\t", @headers); 
	print OUT "\n";
	close OUT;
}

# Counter variables for progress report
my %total;
my %current;
my ($cur, $tot);
while(my $line = <IN>){
	$tot += 1;
	chomp $line;
	my @segs = split(/\t/, $line);
	$total{$segs[-1]} += 1;
	$current{$segs[-1]} = 0;
}
$cur = 0;
close IN;

# Reopening filehandle
open(IN, "< $spreadsheet");
seek(IN, 0, 0);

#my $fqcPool = threadPool->new('maxthreads' => $fqcThreads);

while(my $line = <IN>){
	chomp $line;
	# Split the line into an array based on tab delimiters
	my @segs = split(/\t/, $line);
	# This counter serves to differentiate the read group IDs on the different aligned bam files
	$counter{$segs[-1]} += 1;


	# Generating log position message	
	$cur++;
	$current{$segs[-1]} += 1;
	my $logmsg = sprintf("%0.2f\% through sample %s and %0.2f\% through total files", (($current{$segs[-1]} / $total{$segs[-1]}) * 100), $segs[-1], (($cur / $tot) * 100));

	# If we're generating statistics on all of the fastqs, then fork fastqc
	if($runFQC){
		# file => fastq file, sample => sample_name, library => library_name, readNum => first_or_second_read, log => simpleLogger
		#my $fqcparser1 = fastqcParser->new('file' => $segs[0], 'sample' => $segs[-1], 'library' => $segs[-2], 'readNum' => 1, 'log' => $log);
		#my $fqcparser2 = fastqcParser->new('file' => $segs[1], 'sample' => $segs[-1], 'library' => $segs[-2], 'readNum' => 1, 'log' => $log);
		if(!(-d "$outputfolder/fastqc/$segs[-1]")){
			if(!(-d "$outputfolder/fastqc")){
				mkdir("$outputfolder/fastqc");
			}
			mkdir("$outputfolder/fastqc/$segs[-1]");
		}
		my $fqcdir = "$outputfolder/fastqc/$segs[-1]";
		
		# Running fastqc takes the longest, so we're only going to fork this section
		# my ($file, $sample, $lib, $num, $log, $outfile, $fastqcexe) = @_;
		fork { sub => \&fastqcWrapper, args => [$segs[0], $segs[-1], $segs[-2], 1, $log, $fqcSpreadsheet, $fqcdir, $fastqc], max_proc => $threads };
		fork { sub => \&fastqcWrapper, args => [$segs[1], $segs[-1], $segs[-2], 2, $log, $fqcSpreadsheet, $fqcdir, $fastqc], max_proc => $threads };
		#fastqcWrapper($fqcparser1, $fastqc);
		#fastqcWrapper($fqcparser2, $fastqc);
		
	}	
	
	# The command that creates the new alignment process
	fork { sub => \&runBWAAligner, 
		args => [$segs[0], $segs[1], $refgenome, $reffai, $outputfolder, $segs[-1], $segs[-2], $counter{$segs[-1]}, $log, $errorlog, $javaexe, $javaarg, $picardfolder, $logmsg], 
		max_proc => $threads };
	#runBWAAligner($segs[0], $segs[1], $refgenome, $reffai, $outputfolder, $segs[-1], $segs[-2], $counter{$segs[-1]}, $log, $errorlog, $javaexe, $javaarg, $picardfolder, $logmsg);
	push(@{$bams{$segs[-1]}}, "$outputfolder/$segs[-1]/$segs[-1].$counter{$segs[-1]}.nodup.bam");
}
close IN;
waitall;
#$fqcPool->joinAll();

$log->Info("Spreadsheet", "All alignment threads completed");

# if we ran fastqc, then start parsing the data
if($runFQC){
	$log->Info("Fastqc", "Quality metric data on fastq files located in: $outputfolder/$spreadsheet.fastqc");
}

# After generating all of the bams, now do the merger
$log->Info("Merger", "Beginning bam merger.");
my @finalbams;

my $samexe = SamtoolsExecutable->new('log' => $log);
my $ishts = $samexe->isHTSLib();

foreach my $sample (keys(%bams)){
	my $finalbam = "$outputfolder/$sample/$sample.merged.bam";
	if(scalar(@{$bams{$sample}}) > 1){
		fork { sub => \&samMerge,
			args => [$bams{$sample}, "$outputfolder/$sample", $log, $sample, $ishts],
			max_proc => $threads };
	
		#samMerge($bams{$sample}, "$outputfolder/$sample", $log, $sample);
		#my $thr = threads->create('samMerge', $bams{$sample}, "$outputfolder/$sample", $log, $sample);
		#$mergerPool->submit($thr);

		push(@finalbams, $finalbam);
	}else{
		push(@finalbams, $bams{$sample}->[0]);
	}
}

waitall;
#$mergerPool->joinAll();
$log->Info("Merger", "Finished bam merger.");

#my $snpPool = threadPool->new('maxthreads' => $threads);
if($runSNPFork){
	$log->Info("SNPFORK", "Beginning Samtools SNP calling methods");
	mkdir("$outputfolder/vcfs") || $log->Warn("SNPFORK", "Could not create vcf directory!");
	my @coords;
	if(defined($fastacoords)){
		open(IN, "< $fastacoords") || die $log->Fatal("SNPFORK", "Could not open fasta coordinate file! $fastacoords");
		while(my $line = <IN>){
			chomp $line;
			push(@coords, $line);
		}
		close IN;
	}else{
		open(IN, "< $reffai") || die $log->Fatal("SNPFORK", "Could not open reference fai file! $reffai");
		while(my $line = <IN>){
			chomp $line;
			my @segs = split(/\t/, $line);
			push(@coords, "$segs[0]:1-$segs[1]");
		}
		close IN;
	}
	
	
	my @bcfs;
	my $bamstr = join(",", @finalbams);
	foreach my $c (@coords){	
		my $bcf = "$outputfolder/vcfs/combined.samtools.$c.bcf";
		
		push(@bcfs, $bcf);
		
		$log->Info("[Main]", "Submit: runSamtoolsBCFCaller, args \=\> $refgenome, $bcf, $bamstr, $c, $ishts");
		fork { sub => \&runSamtoolsBCFCaller, args => [$refgenome, $bcf, $bamstr, $c, $ishts], max_proc => $threads };

	}
	
	waitall();
	
	# merge files and call variants
	concatBCFtoVCF(\@bcfs, "$outputfolder/vcfs/combined.samtools.merged.bcf", "$outputfolder/vcfs/combined.samtools.filtered.vcf", $ishts);
	
	# Check to see if the vcf exists and is not empty, then delete bcfs
	if( -s "$outputfolder/vcfs/combined.samtools.filtered.vcf"){
		for(my $x = 0; $x < scalar(@bcfs); $x++){
			system("rm $bcfs[$x]");
		}
	}
	
	if($runSNPEff){
		# TODO: Implement SNPeff annotation of vcf file
	}
}

$log->Info("End", "Run completed successfully");
$log->Close();

exit;
sub fastqcWrapper{
	my ($file, $sample, $lib, $num, $log, $outfile, $fqcdir, $fastqcexe) = @_;
	
	my $fqcParser = fastqcParser->new('file' => $file, 'sample' => $sample, 'library' => $lib, 'readNum' => $num, 'out' => $fqcdir, 'log' => $log);
	$fqcParser->runFastqc($fastqcexe);
	$fqcParser->parseStats();
	$fqcParser->cleanUp();
	
	$fqcParser->writeOutArray($outfile);
}

sub samMerge{
	my ($file_array, $outputdir, $log, $sample, $ishts) = @_;
	
	my $output = "$outputdir/$sample.merged.bam";
	my $filestr = join(" ", @{$file_array});
	
	my $header;
	if($ishts){	
		$log->Info("sammerge", "HTSLIB: samtools merge -cp $output $filestr");
		system("samtools merge -p $output $filestr");
		$log->Info("sammerge", "samtools index $output");
		system("samtools index $output");
	}else{
		$header = headerCreation($file_array, "$outputdir/$sample.header.sam");
		$log->Info("sammerge", "samtools merge -h $header $output $filestr");
		system("samtools merge -h $header $output $filestr");
		$log->Info("sammerge", "samtools index $output");
		system("samtools index $output");
	}
	
	if(-s $output){
		$log->Info("sammerge", "Cleaning up bam files...");
		foreach my $f (@{$file_array}){
			system("rm $f");
			system("rm $f.bai");
		}
	}
	
	if(-s $output && !$ishts){
		system("rm $header");
	}
}

sub headerCreation{
	my ($file_array, $header_name) = @_;
	my %order = ('@HD' => 0, '@SQ' => 1, '@RG' => 2, '@PG' => 3, '@CO' => 4);
	my @store; # [0,1,2,3] -> []
	my $begin = 1;
	
	foreach my $f (@{$file_array}){
		unless(-s $f){
			print "Could not find file: $f for samtools header creation!\n";
		}
		
		open(IN, "samtools view -H $f | ");
		while(my $line = <IN>){
			chomp $line;
			my @segs = split(/\t/, $line);
			
			if(!exists($order{$segs[0]})){next;}
			if($begin && $segs[0] ne '@RG'){
				my $num = $order{$segs[0]};
				push(@{$store[$num]}, $line);
			}elsif($segs[0] eq '@RG'){
				push(@{$store[2]}, $line);
			}
		}
		close IN;
		$begin = 0;
	}
	
	open(OUT, "> $header_name");
	for(my $x = 0; $x < scalar(@store); $x++){
		my %unique;
		foreach my $row (@{$store[$x]}){
			$unique{$row} = 1;
		}
		# Print out only unique lines!
		foreach my $row (keys(%unique)){
			print OUT "$row\n";
		}
	}
	close OUT;
}

# The workhorse subroutine
sub runBWAAligner{
	# Perl needs to read in the arguments to the subroutine
	my ($fq1, $fq2, $ref, $reffai, $outdir, $base, $lib, $num, $log, $errorlog, $java, $javaarg, $picarddir, $logmsg) = @_;
	# Take care of the names of the input and output files
	my $fqbase = basename($fq1);
	my ($fqStr) = $fqbase =~ /(.+)\.(fastq|fq).*/;
	my $bwasam = "$outdir/$base/$base.$num.sam";
	my $bwabam = "$outdir/$base/$base.$num.bam";
	my $bwadedupbam = "$outdir/$base/$base.$num.nodup.bam";
	#my $bwasort = "$outdir/$base/$base.$num.sorted";
	local *TMPOUT = IO::File->new_tmpfile;
	local *TMPERR = IO::File->new_tmpfile;
	my $in = '';
	
	# Create a sub directory if needed
	mkdir("$outdir/$base") || print "";
	
	# Run the BWA mem command and create a bam file from the sam file
	$log->Info("BWAALIGNER", "bwa mem -R '\@RG\\tID:$base.$num\\tLB:$lib\\tPL:ILLUMINA\\tSM:$base\' -v 1 -M $ref $fq1 $fq2 > $bwasam");
	system("bwa mem -R '\@RG\\tID:$base.$num\\tLB:$lib\\tPL:ILLUMINA\\tSM:$base\' -v 1 -M $ref $fq1 $fq2 > $bwasam");
	#my $pid = open3($in, "> $bwasam", ">&TMPERR", "bwa mem -R '\@RG\\tID:$base.$num\\tLB:$lib\\tPL:ILLUMINA\\tSM:$base\' -v 1 -M $ref $fq1 $fq2");
	#waitpid($pid, 0);    
    	
	my $samreader = SamFileReader->new('log' => $log);
	$samreader->prepSam($bwasam);
	#system("samtools view -b -o $bwabam -S $bwasam");
	
	# Sort the bam file
	#print "samtools sort $bwabam $bwasort\n";
	#system("samtools sort $bwabam $bwasort");
	#system("samtools index $bwasort.bam");
	$log->Info("BWAALIGNER", "$java $javaarg -jar $picarddir/MarkDuplicates.jar INPUT=$bwabam OUTPUT=$bwadedupbam METRICS_FILE=$bwadedupbam.metrics VALIDATION_STRINGENCY=LENIENT");
	system("$java $javaarg -jar $picarddir/MarkDuplicates.jar INPUT=$bwabam OUTPUT=$bwadedupbam METRICS_FILE=$bwadedupbam.metrics VALIDATION_STRINGENCY=LENIENT");
	#my $pid = open3($in, ">&TMPOUT", ">&TMPERR", "$java $javaarg -jar $picarddir/MarkDuplicates.jar INPUT=$bwabam OUTPUT=$bwadedupbam METRICS_FILE=$bwadedupbam.metrics VALIDATION_STRINGENCY=SILENT");
	#waitpid($pid, 0);	
	
	$log->Info("BWAALIGNER", "samtools index $bwadedupbam");
	system("samtools index $bwadedupbam");
	#my $pid = open3($in, ">&TMPOUT", ">&TMPERR", "samtools index $bwadedupbam");
	#waitpid($pid, 0);
	
	# If the bam file exists and is not empty, then remove the sam file
	if( -s $bwabam){
		system("rm $bwasam");
		$log->Info("BWAALIGNER", "Completed sorted bam. Removing SAM file");
	}
	
	# $bwabam should be the sorted, indexed bam at the end of the process due to my API
	# I just need to remove the base bam after marking duplicates
	if( -s $bwadedupbam){
		system("rm $bwabam");
		system("rm $bwabam.bai");
		$log->Info("BWAALIGNER", "Completed noduplicate bam. Removing BAM file");
	}
	seek $_, 0, 0 for \*TMPOUT, \*TMPERR;
	while(<TMPOUT>){
		$errorlog->INFO("BWAALIGNER", $_);
	}
	
	while(<TMPERR>){
		$errorlog->Warn("BWAALIGNER", $_);
	}
	
	$log->Info("Pipeline", $logmsg);
}

sub concatBCFtoVCF{
	my ($bcfs, $mergebcf, $vcf, $ishts) = @_;
	
	my $bcfstr = join(' ', @{$bcfs});
	if($ishts){
		system("bcftools concat -o $mergebcf -O b $bcfstr");
		system("bcftools filter -O v -o $vcf -s LOWQUAL -i \'%QUAL>10\' $mergebcf");
	}else{
		system("bcftools cat $bcfstr > $mergebcf");
		system("bcftools view $mergebcf | vcfutils.pl varFilter -D100 > $vcf");
	}
}

sub runSamtoolsBCFCaller{
	my ($ref, $bcf, $bamstr, $chr, $ishts) = @_;
	my @bams = split(/,/, $bamstr);
	my $whitebams = join(' ', @bams);
	
	if($ishts){
		system("samtools mpileup -t DPR -ugf $ref -r $chr $whitebams | bcftools call -vmO b -o $bcf");
	}else{
		system("samtools mpileup -uf $ref -r $chr $whitebams | bcftools view -bvcg - > $bcf"); 
	}
	
	print "Finished creating bcf on chr: $chr\n";
}

sub printAdvancedHelp{
print "
|******************************************|
|    runMergedBamPipeline Advanced Help    |
|******************************************|

Initial setup of configuration and scripts:
--------------------------------------------
	This pipeline requires initial configuration in order to find the appropriate scripts and programs needed to run all settings.
This help menu assumes that you have run the initial perl_toolchain configuration scripts (step1.sh, step2.sh, etc) and that you have downloaded
the following programs and placed them on your PATH: bwa, samtools, bcftools, java(version 1.8), SNPEff and PicardTools. 

	The configuration file defaults to: ~/.mergedpipeline.cnfg and you must at least create this file (or generate a separate file, and run it
using the --config argument) before using the pipeline. A configuration file needs the following entries filled:
	java=<the path to the java executable, including the java executable>
	picard=<the path to the picard jar folder>
	snpeff=<the path to the SNPEff jar folder>
	fastqc=<the path to the fastqc executable>
	runSNP=<boolean flag (values = 0 (don't run) or 1 (run)) to run samtools snp calling>
	runEFF=<boolean flag (values = 0 (don't run) or 1 (run)) to run snpEff on snp calling results>
	runFQC=<boolean flag (values = 0 (don't run) or 1 (run)) to run fastQC on fastq files>
	javaArg=<java executable runtime flags (can be left blank if unsure)> 
	
Note that BWA alignment will always be run on fastq files. All the above entries are mandatory and must be filled with text or numbers.

Setting up a spreadsheet for finding files:
-------------------------------------------
	In order to process files sequentially, the pipeline needs to know where each fastq file is located. In order to feed this information
to the script, you must create a spreadsheet, tab-delimited file ahead of time giving all of the file locations. A spreadsheet file contains the following
tab-delimited information:
	Column 1	Read 1 fastq file
	Column 2	Read 2 fastq file
	Column 3	Library name (this is the name of the physical sequencing library that you used)
	Column 4	Sample name (this is the name of the biological individual that you sampled for making the library)

This file must be tab delimited and must contain at least four columns per row (using the above column scheme). In the case of spreadsheets with longer
columns per line, the last and second to last column will be used for the sample name and library name, respectively.

Using a reference genome:
-------------------------
	The reference genome is perhaps the easiest file to properly configure. For every reference genome you will use, you must:
	1. Run bwa index on the reference genome (e.g. bwa index my.reference.genome.fasta)
	2. Run samtools fasta index (e.g. samtools faidx my.reference.genome.fasta)
	3. Create sequence dictionary with Picard tools (e.g. java -jar CreateSequenceDictionary.jar REFERENCE=my.reference.genome.fasta OUTPUT=my.reference.genome.fasta.dict)

Running the pipeline:
---------------------
	After you have set up a proper configuration file, configured your reference genome and created a tab-delimited spreadsheet with all 
of your fastq file locations, you are set to run the pipeline. You invoke the pipeline using the following command:
	perl /path/to/runMergedBamPipeline.pl --fastqs your.spreadsheet.tab --reference my.reference.genome.fasta --output baseOutputDirectory

Within the output directory, each sample (defined in the last column of the spreadsheet) will have its own individual directory. Within that directory
there will be a merged bam file containing all aligned reads, as well as additional output files if you have specified them in the pipeline. There
will also be a log file in the base output directory that tells you the progress of the pipeline script and stores all error messages.
	Given the long amount of time it takes to align sequence data, it is advisable to use the --threads option to specify how many cpu threads
will be devoted to alignment, variant calling, etc. \n";
exit;
}
