package CJ::Matlab;
# This is the Matlab class of CJ 
# Copyright 2015 Hatef Monajemi (monajemi@stanford.edu) 

use strict;
use warnings;
use CJ;
use Data::Dumper;
use feature 'say';




# class constructor
sub new {
 	my $class= shift;
 	my ($path,$program,$dep_folder) = @_;
	
	my $self= bless {
		path => $path, 
		program => $program,
        dep_folder => $dep_folder
	}, $class;
		
	return $self;
}



sub parse {
	
	my $self=shift;
	
	# script lines will have blank lines or comment lines removed;
	# ie., all remaining lines are effective codes
	# that actually do something.
	my $script_lines;
	    open my $fh, "$self->{path}/$self->{program}" or CJ::err("Couldn't open file: $!");
		while(<$fh>){
	    $_ = $self->uncomment_matlab_line($_);
	    if (!/^\s*$/){
	        $script_lines .= $_;
	    }
	}
	close $fh;
    
	# this includes fors on one line
	my @lines = split('\n|[;,]\s*(?=for)', $script_lines);

    
	my @forlines_idx_set;
	foreach my $i (0..$#lines){
	my $line = $lines[$i];
	    if ($line =~ /^\s*(for.*)/ ){
	        push @forlines_idx_set, $i;
	    }
	}
	# ==============================================================
	# complain if for loops are not 
	# consecutive. We do not allow it in clusterjob.
	# ==============================================================
	&CJ::err(" 'parrun' does not allow less than 1 parallel loops inside the MAIN script.") if($#forlines_idx_set+1 < 1);

	foreach my $i (0..$#forlines_idx_set-1){
	&CJ::err("CJ does not allow anything between the parallel for's. try rewriting your loops.") if($forlines_idx_set[$i+1] ne $forlines_idx_set[$i]+1);
	}

    
	my $TOP;
	my $FOR;
	my $BOT;
    
	foreach my $i (0..$forlines_idx_set[0]-1){
	$TOP .= "$lines[$i]\n";
	}
	foreach my $i ($forlines_idx_set[0]..$forlines_idx_set[0]+$#forlines_idx_set){
	$FOR .= "$lines[$i]\n";
	}
	foreach my $i ($forlines_idx_set[0]+$#forlines_idx_set+1..$#lines){
	$BOT .= "$lines[$i]\n";
	}
	
	
	my $parser ={};
	$parser->{TOP} = $TOP;
	$parser->{FOR} = $FOR;	
	$parser->{BOT} = $BOT;
	$parser->{nloop} = $#forlines_idx_set+1;

	return $parser;
	
}




sub check_initialization{
	my $self = shift;
	
    my ($parser,$tag_list,$verbose) = @_;

	my $BOT = $parser->{BOT};
	my $TOP = $parser->{TOP};
	
	
	
    my @BOT_lines = split /\n/, $BOT;
   
    
    my @pattern;
    foreach my $tag (@$tag_list){
    # grep the line that has this tag as argument
    push @pattern, "\\(.*\\b$tag\\b\.*\\)\|\\{.*\\b$tag\\b\.*\\}";
    }
    my $pattern = join("\|", @pattern);
    
    my @vars;
    foreach my $line (@BOT_lines) {
    
        if($line =~ /(.*)(${pattern})\s*\={1}/){
            my @tmp  = split "\\(|\\{", $line;
            my $var  = $tmp[0];
            #print "$line\n${pattern}:  $var\n";
            $var =~ s/^\s+|\s+$//g;
            push @vars, $var;
        }
    }
    
    foreach(@vars)
    {
        my $line = &CJ::grep_var_line($_,$TOP);
    }

}





sub build_reproducible_script{
	
	my $self = shift;
    my ($runflag) = @_;
	#TODO: add dependecies like CVX, etc.

my $program_script = CJ::readFile("$self->{path}/$self->{program}");
	
my $rp_program_script =<<RP_PRGRAM;

% CJ has its own randState upon calling
% to reproduce results one needs to set
% the internal State of the global stream
% to the one saved when ruuning the code for
% the fist time;
    
load('CJrandState.mat');
globalStream = RandStream.getGlobalStream;
globalStream.State = CJsavedState;
RP_PRGRAM
  
if($runflag =~ /^par.*/){
$rp_program_script .= "addpath(genpath('../.'));\n";
}else{
$rp_program_script .= "addpath(genpath('.'));\n";
}

$rp_program_script .= $program_script ;
    
my $rp_program = "reproduce_$self->{program}";
CJ::writeFile("$self->{path}/$rp_program", $rp_program_script);


}



sub findIdxTagRange
{
	my $self = shift;
	my ($parser,$verbose) = @_;
	
	my $FOR = $parser->{FOR};
	my $TOP = $parser->{TOP};
	
	# Determine the tags and ranges of the
	# indecies
	my @idx_tags;
	my $ranges={};  # This is a hashref $range->{tag}
	my @tags_to_matlab_interpret;
	my @forlines_to_matlab_interpret;
    
    
	    my @forline_list = split /^/, $FOR;
   
	for my $this_forline (@forline_list) {
    
	    my ($idx_tag, $range) = $self->read_matlab_index_set($this_forline, $TOP,$verbose);
    
	    CJ::err("Index tag cannot be established for $this_forline") unless ($idx_tag);
        push @idx_tags, $idx_tag;   # This will keep order.
	    
		if(defined($range)){
	        $ranges->{$idx_tag} = $range;
	    }else{
	        push @tags_to_matlab_interpret, $idx_tag;
	        push @forlines_to_matlab_interpret, $this_forline;
	    }
    
	}


    
	if ( @tags_to_matlab_interpret ) { # if we need to run matlab
	    my $range_run_interpret = $self->run_matlab_index_interpreter($TOP,\@tags_to_matlab_interpret,\@forlines_to_matlab_interpret, $verbose);
    
    
	    for (keys %$range_run_interpret){
	    	$ranges->{$_} = $range_run_interpret->{$_};
	    	#print"$_:$range_run_interpret->{$_} \n";
	    }
	}
    
	return (\@idx_tags,$ranges);
}






sub read_matlab_index_set
{
	my $self = shift;
	
    my ($forline, $TOP, $verbose) = @_;
    
    chomp($forline);
    $forline = $self->uncomment_matlab_line($forline);   # uncomment the line so you dont deal with comments. easier parsing;
    
    
    # split at equal sign.
    my @myarray    = split(/\s*=\s*/,$forline);
    my @tag     = split(/\s/,$myarray[0]);
    my $idx_tag = $tag[-1];
    
    
  
    
    my $range = undef;
    # The right of equal sign
    my $right  = $myarray[1];
    # see if the forline contains :
    if($right =~ /^[^:]+:[^:]+$/){
        my @rightarray = split( /\s*:\s*/, $right, 2 );
        
        my $low =$rightarray[0];
        if(! &CJ::isnumeric($low) ){
            &CJ::err("The lower limit of for MUST be numeric for this version of clusterjob\n");
        }
        
		# remove white space
        $rightarray[1]=~ s/^\s+|\s+$//g;
		
		
        if($rightarray[1] =~ /\s*length\(\s*(.+?)\s*\)/){
            
            #CASE i = 1:length(var);
            # find the variable;
            my ($var) = $rightarray[1] =~ /\s*length\(\s*(.+?)\s*\)/;
            my $this_line = &CJ::grep_var_line($var,$TOP);
            
            #extract the range
            my @this_array    = split(/\s*=\s*/,$this_line);
            
            
            my $numbers;
            if($this_array[1] =~ /\[\s*([^:]+?)\s*\]/){
            ($numbers) = $this_array[1] =~ /\[\s*(.+?)\s*\]/;
            my $floating_pattern = "[-+]?[0-9]*[\.]?[0-9]+(?:[eE][-+]?[0-9]+)?";
            my $fractional_pattern = "(?:${floating_pattern}\/)?${floating_pattern}";
            my @vals = $numbers =~ /[\;\,]?($fractional_pattern)[\;\,]?/g;
             
            my $high = 1+$#vals;
            my @range = ($low..$high);
            $range = join(',',@range);
                
            }
            
           
            
        }elsif($rightarray[1] =~ /\s*(\D+)\s*/) {
            #print "$rightarray[1]"."\n";
            # CASE i = 1:L
            # find the variable;
            
			
            my ($var) = $rightarray[1] =~ /\s*(\w+)\s*/;
			
            my $this_line = &CJ::grep_var_line($var,$TOP);
            
            #extract the range
            my @this_array    = split(/\s*=\s*/,$this_line);
            my ($high) = $this_array[1] =~ /\[?\s*(\d+)\s*\]?/;
            
            
            if(! &CJ::isnumeric($high) ){
                $range = undef;
            }else{
                my @range = ($low..$high);
                $range = join(',',@range);
            }
        }elsif($rightarray[1] =~ /.*(\d+).*/){
            # CASE i = 1:10
            my ($high) = $rightarray[1] =~ /^\s*(\d+).*/;
            my @range = ($low..$high);
            $range = join(',',@range);
            
        }else{
            
            
            $range = undef;
            #&CJ::err("strcuture of for loop not recognized by clusterjob. try rewriting your for loop using 'i = 1:10' structure");
            
        }
        
   
        # Other cases of for loop to be considered.
        
        
        
    }
 

    return ($idx_tag, $range);
}




sub run_matlab_index_interpreter{
	my $self = shift;
    my ($TOP,$tag_list,$for_lines,$verbose) = @_;

	&CJ::message("Invoking MATLAB to find range of indices. Please be patient...");

    
    # Check that the local machine has MATLAB (we currently build package locally!)
	# Open matlab  and eval

my $test_name= "/tmp/CJ_matlab_test";
my $test_file = "\'$test_name\'";

my $matlab_check_script = <<MATLAB_CHECK;
test_fid = fopen($test_file,'w+');
fprintf(test_fid,\'%s\', 'test_passed');
fclose(test_fid);
MATLAB_CHECK

my $check_path = "/tmp";
my $check_name= "CJ_matlab_check_script.m";

&CJ::writeFile("$check_path/$check_name",$matlab_check_script);


my $junk = "/tmp/CJ_matlab.output"; 

    
    
my $matlab_check_bash = <<CHECK_BASH;
#!/bin/bash -l
  matlab -nodisplay -nodesktop -nosplash  < '$check_path/$check_name'  &>$junk;
CHECK_BASH
   
   
   
&CJ::message("Checking command 'matlab' is available...",1);

CJ::my_system("source ~/.bash_profile; source ~/.bashrc; printf '%s' $matlab_check_bash",$verbose);  # this will generate a file test_file

eval{
    my $check = &CJ::readFile($test_name);     # this causes error if there is no file which indicates matlab were not found.
	#print $check . "\n";
};
if($@){
	#print $@ . "\n";
&CJ::err("CJ requires 'matlab' but it cannot access it. Consider adding alias 'matlab' in your ~/.bashrc or ~/.bash_profile");	
}else{
&CJ::message("matlab available.",1);	
};   
   
	
	#
    # my $check_matlab_installed = `source ~/.bashrc ; source ~/.profile; source ~/.bash_profile; command -v matlab`;
    # if($check_matlab_installed eq ""){
    # &CJ::err("I require matlab but it's not installed: The following check command returned null. \n     `source ~/.bashrc ; source ~/.profile; command -v matlab`");
    # }else{
    # &CJ::message("Test passed, Matlab is installed on your machine.");
    # }
    # 

# build a script from top to output the range of index
    
# Add top
my $matlab_interpreter_script=$TOP;

    
# Add for lines
foreach my $i (0..$#{$for_lines}){
    my $tag = $tag_list->[$i];
    my $forline = $for_lines->[$i];
    
        # print  "$tag: $forline\n";
    
   	 my $tag_file = "\'/tmp/$tag\.tmp\'";
$matlab_interpreter_script .=<<MATLAB
$tag\_fid = fopen($tag_file,'w+');
$forline
fprintf($tag\_fid,\'%i\\n\', $tag);
end
fclose($tag\_fid);
MATLAB
}
    #print  "$matlab_interpreter_script\n";
    
    my $name = "CJ_matlab_interpreter_script.m";
    my $path = "/tmp";
    &CJ::writeFile("$path/$name",$matlab_interpreter_script);
    #&CJ::message("$name is built in $path",1);

    
    
#FIXME: addpath(genpath('$self->{path}/$self->{dep_folder}'));
# This needs to direct to only the dep folder. Otherwise you may pick up
# Things, you dont need and this causes crash.
# ALso if this is not successful and doesnt give index.tmp, we need to issue error.
    
my $matlab_interpreter_bash = <<BASH;
#!/bin/bash -l
# dump everything user-generated from top in /tmp
cd /tmp/
matlab -nodisplay -nodesktop -nosplash  <<HERE &>$junk;
addpath(genpath('$self->{path}'));
run('$path/$name')
HERE
BASH


    #my $bash_name = "CJ_matlab_interpreter_bash.sh";
    #my $bash_path = "/tmp";
    #&CJ::writeFile("$bash_path/$bash_name",$matlab_interpreter_bash);
    #&CJ::message("$bash_name is built in $bash_path");

&CJ::message("finding range of indices...",1);
CJ::my_system("source ~/.bash_profile; source ~/.bashrc; printf '%s' $matlab_interpreter_bash",$verbose);  # this will generate a 
&CJ::message("Closing Matlab session!",1);
    
# Read the files, and put it into $numbers
# open a hashref
my $range={};
foreach my $tag (@$tag_list){
    my $tag_file = "/tmp/$tag\.tmp";
    my $tmp_array = &CJ::readFile("$tag_file");
    my @tmp_array  = split /\n/,$tmp_array;
    $range->{$tag} = join(',', @tmp_array);
    # print $range->{$tag} . "\n";
	&CJ::my_system("rm -f $tag_file", $verbose) ; #clean /tmp  
}


# remove the files you made in /tmp
&CJ::my_system("rm -f $test_name $junk $check_path/$check_name $path/$name");

    return $range;
	
}





sub uncomment_matlab_line{
	my $self = shift;
	
    my ($line) = @_;
    $line =~ s/^(?:(?!\').)*\K\%(.*)//;
    
    return $line;
}




















sub make_MAT_collect_script
{
	my $self = shift;
	
my ($res_filename, $completed_filename, $bqs) = @_;
    
my $collect_filename = "collect_list.cjr";
    
my $matlab_collect_script=<<MATLAB;
\% READ completed_list.cjr and FIND The counters that need
\% to be collected
completed_list = load('$completed_filename');

if(~isempty(completed_list))


\%determine the structre of the output
if(exist('$res_filename', 'file'))
    \% CJ has been called before
    res = load('$res_filename');
    start = 1;
else
    \% Fisrt time CJ is being called
    res = load([num2str(completed_list(1)),'/$res_filename']);
    start = 2;
    
    
    \% delete the line from remaining_filename and add it to collected.
    \%fid = fopen('$completed_filename', 'r') ;               \% Open source file.
    \%fgetl(fid) ;                                            \% Read/discard line.
    \%buffer = fread(fid, Inf) ;                              \% Read rest of the file.
    \%fclose(fid);
    \%delete('$completed_filename');                         \% delete the file
    \%fid = fopen('$completed_filename', 'w')  ;             \% Open destination file.
    \%fwrite(fid, buffer) ;                                  \% Save to file.
    \%fclose(fid) ;
    
    if(~exist('$collect_filename','file'));
    fid = fopen('$collect_filename', 'a+');
    fprintf ( fid, '%d\\n', completed_list(1) );
    fclose(fid);
    end
    
    percent_done = 1/length(completed_list) * 100;
    fprintf('\\n SubPackage %d Collected (%3.2f%%)', completed_list(1), percent_done );

    
end

flds = fields(res);


for idx = start:length(completed_list)
    count  = completed_list(idx);
    newres = load([num2str(count),'/$res_filename']);
    
    for i = 1:length(flds)  \% for all variables
        res.(flds{i}) =  CJ_reduce( res.(flds{i}) ,  newres.(flds{i}) );
    end

\% save after each packgae
save('$res_filename','-struct', 'res');
percent_done = idx/length(completed_list) * 100;
    
\% delete the line from remaining_filename and add it to collected.
\%fid = fopen('$completed_filename', 'r') ;              \% Open source file.
\%fgetl(fid) ;                                      \% Read/discard line.
\%buffer = fread(fid, Inf) ;                        \% Read rest of the file.
\%fclose(fid);
\%delete('$completed_filename');                         \% delete the file
\%fid = fopen('$completed_filename', 'w')  ;             \% Open destination file.
\%fwrite(fid, buffer) ;                             \% Save to file.
\%fclose(fid) ;

if(~exist('$collect_filename','file'));
    error('   CJerr::File $collect_filename is missing. CJ stands in AWE!');
end

fid = fopen('$collect_filename', 'a+');
fprintf ( fid, '%d\\n', count );
fclose(fid);
    
fprintf('\\n SubPackage %d Collected (%3.2f%%)', count, percent_done );
end

   

end

MATLAB




my $HEADER= &CJ::bash_header($bqs);

my $script;
if($bqs eq "SGE"){
$script=<<BASH;
$HEADER
echo starting collection
echo FILE_NAME $res_filename


module load MATLAB-R2014a;
matlab -nosplash -nodisplay <<HERE

$matlab_collect_script

quit;
HERE

echo ending colection;
echo "done"
BASH
}elsif($bqs eq "SLURM"){
$script= <<BASH;
$HEADER
echo starting collection
echo FILE_NAME $res_filename

module load matlab;
matlab -nosplash -nodisplay <<HERE

$matlab_collect_script

quit;
HERE

echo ending colection;
echo "done"
BASH

}

    
    return $script;
}









########################
sub CJrun_body_script{
########################
    my $self = shift;
    my ($ssh) = @_;
    
    
&CJ::err("Matlab module not defined in ssh_config file.") if not defined $ssh->{'mat'};
    
my $script =<<'BASH';
    
module load <MATLAB_MODULE>
unset _JAVA_OPTIONS
matlab -nosplash -nodisplay <<HERE
<MATPATH>

% make sure each run has different random number stream
myversion = version;
mydate = date;
RandStream.setGlobalStream(RandStream('mt19937ar','seed', sum(100*clock)));
globalStream = RandStream.getGlobalStream;
CJsavedState = globalStream.State;
fname = sprintf('CJrandState.mat');
save(fname,'myversion','mydate', 'CJsavedState');
cd $DIR
run('${PROGRAM}');
quit;
HERE
    
BASH

    
    
my $pathText.=<<MATLAB;
% add user defined path
addpath $ssh->{matlib} -begin

% generate recursive path
addpath(genpath('.'));

try
cvx_setup;
cvx_quiet(true)
% Find and add Sedumi Path for machines that have CVX installed
cvx_path = which('cvx_setup.m');
oldpath = textscan( cvx_path, '%s', 'Delimiter', '/');
newpath = horzcat(oldpath{:});
sedumi_path = [sprintf('%s/', newpath{1:end-1}) 'sedumi'];
addpath(sedumi_path)

catch
warning('CVX not enabled. Please set CVX path in .ssh_config if you need CVX for your jobs');
end

MATLAB

$script =~ s|<MATPATH>|$pathText|;
$script =~ s|<MATLAB_MODULE>|$ssh->{mat}|;


    return $script;
    
}




##########################
sub CJrun_par_body_script{
##########################
    my $self = shift;
    my ($ssh) = @_;
    
&CJ::err("Matlab module not defined in ssh_config file.") if not defined $ssh->{'mat'};

my $script =<<'BASH';

module load <MATLAB_MODULE>
unset _JAVA_OPTIONS
matlab -nosplash -nodisplay <<HERE
<MATPATH>


% add path for parrun
oldpath = textscan('$DIR', '%s', 'Delimiter', '/');
newpath = horzcat(oldpath{:});
bin_path = sprintf('%s/', newpath{1:end-1});
addpath(genpath(bin_path));


% make sure each run has different random number stream
myversion = version;
mydate = date;
% To get different Randstate for different jobs
rng(${COUNTER})
seed = sum(100*clock) + randi(10^6);
RandStream.setGlobalStream(RandStream('mt19937ar','seed', seed));
globalStream = RandStream.getGlobalStream;
CJsavedState = globalStream.State;
fname = sprintf('CJrandState.mat');
save(fname,'myversion', 'mydate', 'CJsavedState');
cd $DIR
run('${PROGRAM}');
quit;
HERE

BASH
    
    
    
my $pathText.=<<MATLAB;

% add user defined path
addpath $ssh->{matlib} -begin

% generate recursive path
addpath(genpath('.'));

try
cvx_setup;
cvx_quiet(true)
% Find and add Sedumi Path for machines that have CVX installed
cvx_path = which('cvx_setup.m');
oldpath = textscan( cvx_path, '%s', 'Delimiter', '/');
newpath = horzcat(oldpath{:});
sedumi_path = [sprintf('%s/', newpath{1:end-1}) 'sedumi'];
addpath(sedumi_path)

catch
warning('CVX not enabled. Please set CVX path in .ssh_config if you need CVX for your jobs');
end

MATLAB
   
    
$script =~ s|<MATPATH>|$pathText|;
$script =~ s|<MATLAB_MODULE>|$ssh->{mat}|;

    
    return $script;
}



























#############################
sub buildParallelizedScript{
#############################
my $self = shift;
my ($TOP,$FOR,$BOT,@tag_idx) = @_;

my @str;
while(@tag_idx){
   my $tag = shift @tag_idx;
   my $idx = shift @tag_idx;
   push @str , "$tag~=$idx";
}

my $str = join('||',@str);


my $INSERT = "if ($str); continue;end";
my $new_script = "$TOP \n $FOR \n $INSERT \n $BOT";
undef $INSERT;
return $new_script;
}



















1;
