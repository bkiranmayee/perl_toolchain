# perl_toolchain
Backup for my personal perl scripts

In order to install prerequisite modules to run these scripts, please use the installation shell scripts in the base directory of the repository in the order that they are listed.

The first step is to generate a local::lib bootstrap that will create the necessary folders and environmental variables for Perl to use for installing future modules. In order to accomplish this, you simply need to run the following command within the "perl_toolchain" directory in your $HOME folder:

```bash
$ sh step1_locallib_install.sh
```

After this completes, you need to restart your shell session (or reboot the machine) in order to apply the changes to your current session. After rebooting, you will then download the necessary Perl modules by using this command within the "perl_toolchain" folder:

```bash
$ sh step2_required_library_install.sh
```

This will take some time, but after it is finished, you should be able to run just about all of the scripts

The final test will check to see if you have the required third-party programs installed on your system and in your current $PATH environmental variable.

```bash
$ perl step3_check_path_for_third_party_programs.pl
```

If the script returns any errors, please search for these tools online and install them as per the instructions of their respective authors. The executables for these programs must be in your path to be used by the scripts (ie. in your ~/bin folder).

# Troubleshooting
There is an issue with the Forks::Super library that might cause errors during the installation. If you receive an error at the end of the "step 2" script, please try reinstalling the module by running the following command:

```bash
$ cpanm --verbose Forks::Super
```

This should install the library properly after a lengthy series of tests.

# Directory contents
Each directory contains individual, stand-alone scripts that are meant to process specific datasets or perform specific forms of analysis. The README.md file within each directory contains usage information and brief summaries of the scripts in order to aid user adoption. In general, the directory contents follow this structure:


* **assembly_scripts**		Contains scripts to process genome assembly data or statistics
* **bed_cnv_fig_table_pipeline**	Contains scripts that summarize bed file contents
* **personal_modules**	A private library that contains modules that are used commonly in my scripts
* **sequence_data_pipeline**	A pipeline for processing Illumina sequence data
* **sequence_data_scripts**	Contains scripts that parse sequence data files and create summary statistics
* **simulations**	Contains scripts devoted to simulation and simulated data
* **snp_utilities**	Contains scripts for analyzing and summarizing SNP data formats
* **vcf_utils**	Specific utilities designed for navigating VCF files