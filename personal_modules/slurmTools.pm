#!/usr/bin/perl
# Tools to initiate Slurm shell script generation and execution
# ver 2: added partition option

package slurmTools;
use Mouse;
use namespace::autoclean;

has ['workDir', 'scriptDir', 'outDir', 'errDir'] => (is => 'ro', isa => 'Str', required => 1);
has 'useTime' => (is => 'rw', isa => 'Bool', default => 1);
has 'modules' => (is => 'rw', isa => 'ArrayRef[Any]', predicate => 'has_module');
has ['nodes', 'tasks', 'mem', 'time'] => (is => 'rw', isa => 'Any', default => -1);
has 'scripts' => (traits => ['Array'], is => 'rw', isa => 'ArrayRef[Any]', default => sub{[]}, handles => {
		'add_script' => 'push',
	});
has 'jobIds' => (is => 'rw', isa => 'ArrayRef[Any]', predicate => 'has_jobs');
has 'dependencies' => (is => 'rw', isa => 'ArrayRef[Any]', predicate => 'has_dep');
has 'partition' => (is => 'rw', isa => 'Str', predicate => 'has_part');

sub checkJobs{
	my ($self) = @_;
	
	if($self->has_jobs){
		my @jobIds = @{$self->jobIds};
		my @incomplete;
		foreach my $j (@jobIds){
			my $output = `squeue -j $j`;
			if($output =~ /slurm_load_jobs error:/){
				push(@incomplete, $j);
			}
		}
		$self->jobIds(@incomplete);
		if(scalar(@incomplete) > 0){
			return 0;
		}else{
			return 1;
		}
	}else{
		return -1;
	}
}
			

sub queueJobs{
	my ($self) = @_;
	
	my @scripts = @{$self->scripts};
	my @jobIds;
	foreach my $s (@scripts){
		my $jid = `sbatch $s`;
		chomp $jid;
		my ($job) = $jid =~ /(\d+)/;
		push(@jobIds, $job);
	}
	$self->jobIds(\@jobIds);
}

sub createArrayCmd{
	my ($self, $carrayref, $sbase) = @_;
	# Requires an array ref of premade cmds for a single script
	$self->_generateFolders;
	if(!defined($sbase)){
		$sbase = "script_";
	}
	my $hash = $self->_generateSHash($sbase);
	$sbase .= "$hash.sh";
	my $time = ($self->useTime)? "time " : "";
	
	my $head = $self->_generateHeader($sbase);
	
	foreach my $cmd (@{$carrayref}){
		$head .= "echo \"$cmd\"\n$time$cmd\n\n";
	}
	$head .= "wait\n";
	
	my $sFolder = $self->scriptDir;
	open(my $OUT, "> $sFolder/$sbase") || die "Could not create script!\n";
	print {$OUT} $head;
	close $OUT;
	$self->add_script("$sFolder/$sbase");
}

sub createGenericCmd{
	my ($self, $cmd, $sname) = @_;
	# Requires detailed command statement and [optionally] a script name
	$self->_generateFolders;
	if(!defined($sname)){
		my $hash = $self->_generateSHash($cmd);
		$sname = "script_$hash.sh";
	}else{
		my $hash = $self->_generateSHash($cmd);
		$sname = "$sname\_$hash.sh";
	}
	my $time = ($self->useTime)? "time " : "";
	
	my $head = $self->_generateHeader($sname);
	$head .= "echo \"$cmd\"\n$time$cmd\nwait\n";
	
	my $sFolder = $self->scriptDir;
	open(my $OUT, "> $sFolder/$sname") || die "Could not create script!\n";
	print {$OUT} $head;
	close $OUT;
	$self->add_script("$sFolder/$sname");
}

sub _generateFolders{
	my ($self) = @_;
	mkdir $self->workDir || print "$!\n";
	mkdir $self->scriptDir || print "$!\n";
	mkdir $self->outDir || print "$!\n";
	mkdir $self->errDir || print "$!\n";
}

sub _generateSHash{
	my ($self, $cmd) = @_;
	# Generates unique hash from command name
	
	my $h = 0;
	
	my @random_set;
	my %seen;

	for (1..5) {
    		my $candidate = int rand(1185);
   		redo if $seen{$candidate}++;
    		push @random_set, $candidate;
	}

	$h = join("", @random_set);
	
	return $h;
}
	

sub _generateHeader{
	my ($self, $sname) = @_;
	my $meta = __PACKAGE__->meta;
	my $tag = "#SBATCH";
	my $str = "#!/bin/bash\n";
	if($self->nodes != -1){
		$str .= "$tag --nodes=" . $self->nodes . "\n";
	}
	if($self->tasks != -1){
		$str .= "$tag --ntasks-per-node=" . $self->tasks . "\n";
	}
	if($self->mem != -1){
		$str .= "$tag --mem=" . $self->mem . "\n";
	}
	if($self->time != -1){
		$str .= "$tag --time=" . $self->time . "\n";
	}
	if($self->has_part){
		$str .= "$tag --partition=" . $self->partition . "\n";
	}
	if($self->has_dep){
		my @dependencies = @{$self->dependencies};
		chomp(@dependencies);
		my $depStr = "afterany";
		foreach my $d (@dependencies){
			$depStr .= ":$d";
		}
		
		$str .= "$tag --dependency=$depStr\n";
	}
		
	$str .= "$tag --output=" . $self->outDir . "/$sname\_%j.out\n$tag --error=" . $self->errDir . "/$sname\_%j.err\n$tag --workdir=" . $self->workDir . "\n\n";
	
	$str .= "cd " . $self->workDir . "\n\n";
	
	if($self->has_module){
		foreach my $m (@{$self->modules}){
			$str .= "module load $m\n";
		}
		$str .= "\n";
	}
		
	return $str;
}


__PACKAGE__->meta->make_immutable;

1;
