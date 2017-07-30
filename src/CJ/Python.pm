package CJ::Python;
# This is the Python class of CJ
# Copyright 2017 Hatef Monajemi (monajemi@stanford.edu)

use strict;
use warnings;
use CJ;
use Data::Dumper;
use feature 'say';



####################
sub new {
####################
 	my $class= shift;
 	my ($path,$program,$dep_folder) = @_;
	
	my $self= bless {
		path => $path, 
		program => $program,
        dep_folder => $dep_folder
	}, $class;
		
	return $self;
}


#####################
sub parse {
#####################
	my $self = shift;
	
	# script lines will have blank lines or comment lines removed;
	# ie., all remaining lines are effective codes
	# that actually do something.
	my $script_lines;
	    open my $fh, "$self->{path}/$self->{program}" or CJ::err("Couldn't open file: $!");
		while(<$fh>){
            $_ = $self->uncomment_python_line($_);
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
	    if ($line =~ /^[\t\s]*(for.*)/ ){
	        push @forlines_idx_set, $i;
	    }
	}
    
	# ==============================================================
	# complain if for loops are not 
	# consecutive. We do not allow it in clusterjob.
	# ==============================================================
	&CJ::err(" 'parrun' does not allow less than 1 parallel loops inside the MAIN script.") if ($#forlines_idx_set+1 < 1);

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




##################################
sub build_reproducible_script{
##################################
my $self = shift;
my ($runflag) = @_;

my $program_script = CJ::readFile("$self->{path}/$self->{program}");

my $rp_program_script =<<'RP_PRGRAM';

# CJ has its own randState upon calling
# to reproduce results one needs to set
# the internal State of the global stream
# to the one saved when ruuning the code for
# the fist time;
import os,sys,pickle,numpy,random;
CJsavedState = pickle.load(open('CJrandState.pickle','rb'));
numpy.random.set_state(CJsavedState['numpy_CJsavedState']);
random.setstate(CJsavedState['CJsavedState']);
    
RP_PRGRAM

    
if($runflag =~ /^par.*/){
    $rp_program_script .= "sys.path.append('../.');\n"
}else{
    $rp_program_script .= "sys.path.append('.');\n"
}

$rp_program_script .= $program_script ;

my $rp_program = "reproduce_$self->{program}";
CJ::writeFile("$self->{path}/$rp_program", $rp_program_script);
    
}







#######################
sub CJrun_body_script{
#######################
    my $self = shift;
    my ($ssh) = @_;
    
# Determine easy_install version
my $python_version_tag = "";
&CJ::err("python module not defined in ssh_config file.") if not defined $ssh->{'py'};
    
if( $ssh->{'py'} =~ /python\D?((\d.\d).\d)/i ) {
    $python_version_tag = "-".$2;
}elsif( $ssh->{'py'} =~ /python\D?(\d.\d)/i ){
    $python_version_tag = "-".$1;
}else{
    CJ::err("Cannot decipher pythonX.Y.Z version");
}

my $user_required_pyLib = join (" ", split(":",$ssh->{'pylib'}) );
        
my $script =<<'BASH';
    
<PYTHONLIB>

<PYTHON_MODULE> <<HERE
    
# make sure each run has different random number stream
import os,sys,pickle,numpy,random;

mydate = numpy.datetime64('now');
#sum(100*clock)
seed = numpy.sum(100*numpy.array([mydate.astype(object).year, mydate.astype(object).month, mydate.astype(object).day, mydate.astype(object).hour, mydate.astype(object).minute, mydate.astype(object).second]));

    
# Set the seed for numpy and python
random.seed(seed);
numpy.random.seed(seed);
    
CJsavedState = {'myversion': sys.version, 'mydate':mydate, 'numpy_CJsavedState': numpy.random.get_state(), 'CJsavedState': random.getstate()}
    
fname = "$DIR/CJrandState.pickle";
with open(fname, 'wb') as RandStateFile:
	pickle.dump(CJsavedState, RandStateFile);

# CJsavedState = pickle.load(open('CJrandState.pickle','rb'));
    
os.chdir("$DIR")
import ${PROGRAM};
exit();
HERE

# Get out of virtual env and remove it
source deactivate
conda remove --yes -n $HOME/python_venv_$PID --all
    
BASH
    

    
my $libs =<<LIB;

# anaconda is assumed to be installed
# prior to this
    
# activate python venv
source activate python_venv_\$PID
conda install -n python_venv_\$PID numpy $user_required_pyLib


# Freez the environment after you installed all the modules
# Reproduce with:
#      conda create --yes -n python_venv_\$PID --file req.txt
conda list -e > \${DIR}/\$PID_py_conda_req.txt

LIB

$script =~ s|<PYTHONLIB>|$libs|;
$script =~ s|<PYTHON_MODULE>|$ssh->{'py'}|g;


return $script;
    
}




##########################
sub CJrun_par_body_script{
##########################
    
    my $self = shift;
    my ($ssh) = @_;
    
# Determine easy_install version
my $python_version_tag = "";
&CJ::err("python module not defined in ssh_config file.") if not defined $ssh->{'py'};
if( $ssh->{'py'} =~ /python.?((\d.\d).\d)/ ) {
$python_version_tag = "-".$2;
}

# Libraries required
my $user_required_pyLib = join (" ", split(":",$ssh->{'pylib'}) );

    
my $script =<<'BASH';

module load <PYTHON_MODULE>

<PYTHONLIB>

python <<HERE

# make sure each run has different random number stream
import os,sys,pickle,numpy,random;
    
# Add path for parrun
deli  = "/";
path  = os.getcwd();
path  = path.split(deli);
path.pop();
sys.path.append(deli.join(path));
    
#GET A RANDOM SEED FOR THIS COUNTER
numpy.random.seed(${COUNTER});
seed_0 = numpy.random.randint(10**6);
mydate = numpy.datetime64('now');
#sum(100*clock)
seed_1 = numpy.sum(100*numpy.array([mydate.astype(object).year, mydate.astype(object).month, mydate.astype(object).day, mydate.astype(object).hour, mydate.astype(object).minute, mydate.astype(object).second]));
#seed = sum(100*clock) + randi(10^6);
seed = seed_0 + seed_1;

    
# Set the seed for python and numpy (for reproducibility purposes);
random.seed(seed);
numpy.random.seed(seed);

CJsavedState = {'myversion': sys.version, 'mydate':mydate, 'numpy_CJsavedState': numpy.random.get_state(), 'CJsavedState': random.getstate()}

fname = "$DIR/CJrandState.pickle";
with open(fname, 'wb') as RandStateFile:
	pickle.dump(CJsavedState, RandStateFile);

# del vars that we create tmp
del deli,path,seed_0,seed_1,seed,CJsavedState;
    
# CJsavedState = pickle.load(open('CJrandState.pickle','rb'));

os.chdir("$DIR")
import ${PROGRAM};
exit();
HERE

# Get out of virtual env and remove it
deactivate
rm -rf $HOME/python_venv_$PID;

BASH



my $libs =<<LIB;
# Install required software in a virtualenv
# This can be different when Container used.

easy_install$python_version_tag --user pip
python -m pip install --user --upgrade pip
python -m pip install --user --upgrade virtualenv
python -m virtualenv \$HOME/python_venv_\$PID ;
source \$HOME/python_venv_\$PID/bin/activate
pip install numpy $user_required_pyLib

# Freez the environment after you installed all the modules
pip freeze > \${DIR}/python_requirements.txt

LIB

$script =~ s|<PYTHONLIB>|$libs|;
$script =~ s|<PYTHON_MODULE>|$ssh->{'py'}|;


return $script;
}



################################
sub read_python_array_values{
################################
    my $self = shift;
    my ($string) = @_;
    
    my $floating_pattern = "[-+]?[0-9]*[\.]?[0-9]+(?:[eE][-+]?[0-9]+)?";
    my $fractional_pattern = "(?:${floating_pattern}\/)?${floating_pattern}";
    my @vals = undef;
    
    if($string =~ /(.*array\(\[)?\s*($fractional_pattern)+\s*(\]\))?/){
        my ($numbers) = $string =~ /(?:.*array\(\[)?\s*(.+)\s*(?:\]\))?/;
        @vals = $numbers =~ /[\;\,]?($fractional_pattern)[\;\,]?/g;
    }
    return @vals;
}


#############################################################
# This function is used for parsing the content of _for_ line
# low and high limits of the loop
sub read_python_lohi{
#############################################################
    my $self  = shift;
    my ($input,$TOP) = @_;
    
    my $lohi = undef;
    
    if( &CJ::isnumeric($input) ) {
        $lohi = $input;
        
    }elsif ($input =~ /\s*len\(\s*(.+)\s*\)/) {
        my $this_line = &CJ::grep_var_line($1,$TOP);
        #extract the range
        my @this_array    = split(/\s*=\s*/,$this_line);
        
        my @vals = $self->read_python_array_values($this_array[1]);  # This reads the vals;
        $lohi = 1+$#vals;
        $lohi = undef if (!&CJ::isnumeric($lohi));
        
    }elsif($input =~ /\s*(\D+)\s*:/){
        # CASE var
        my $this_line = &CJ::grep_var_line($1,$TOP);
        
        #extract the range
        my @this_array    = split(/\s*=\s*/,$this_line);
        
        $lohi = ($self->read_python_array_values($this_array[1]))[0];  # This reads a number;
        $lohi = undef if (!&CJ::isnumeric($lohi));
    }
    
    return $lohi;
}




##########################
sub read_python_index_set{
##########################
    my $self = shift;
    
    my ($forline, $TOP, $verbose) = @_;
    
    chomp($forline);
    
    
    # split at 'in' keyword.
    my @myarray    = split(/\s*\bin\b\s*/,$forline);
    my @tag        = split(/\s/,$myarray[0]);
    my $idx_tag    = $tag[-1];
    
    
    my $range = undef;   # This will be defined below
    # The right of in keyword
    my $right  = $myarray[1];
    
    
    # see if the for line contains range
    if($right =~ /\s*x?range\(\s*(.+)\s*\)/){
        
        my @rightarray = split( /\s*,\s*/, $1);
        
        if($#rightarray == 0){
            #CASE i in range(stop);
            my $low     = 0;
            my $high    = $self->read_python_lohi($rightarray[0],$TOP);
            $range      = join(',',($low..$high-1)) if defined($high);
            
        }elsif($#rightarray == 1){
            #CASE i in range(start,stop);
            my $low  = $self->read_python_lohi($rightarray[0],$TOP);
            my $high = $self->read_python_lohi($rightarray[1],$TOP);
            $range      = join(',',($low..$high-1)) if defined($high);
            
        }elsif($#rightarray == 2){
            #CASE i in range(start,stop, step);
            my $low  = $self->read_python_lohi($rightarray[0],$TOP);
            my $high = $self->read_python_lohi($rightarray[1],$TOP);
            my $step = $self->read_python_lohi($rightarray[2],$TOP);
            
            if( defined($low) && defined($high) && defined($step)){
                
                my @range;
                for (my $i = $low; $i < $high; $i += $step) {
                    push @range, $i;
                }
                $range      = join(',',@range);
            }
        }else{
            &CJ::err("invalid argument to range(start, stop[, step]). $!");
        }
        
    }elsif($right =~ /^\s*(\w+)\s*:$/){

        #CASE: for i in array;
        print $1 . "\n";
        my $this_line = &CJ::grep_var_line($1,$TOP);
        #extract the range
        my @this_array    = split(/\s*=\s*/,$this_line);
        my @range = $self->read_python_array_values($this_array[1]);
        
        $range      = join(',',@range);
        
    }else{
        
        

        
        $range = undef;
        #&CJ::err("strcuture of for loop not recognized by clusterjob. try rewriting your for loop using 'i = 1:10' structure");
        
    }
    return ($idx_tag, $range);
}




##################################
sub run_python_index_interpreter{
##################################
my $self = shift;
my ($TOP,$tag_list,$for_lines,$verbose) = @_;

&CJ::message("Invoking Python to find range of indices. Please be patient...");
    
    
# Check that the local machine has Python (we currently build package locally!)
# Open python and eval

my $test_name= "/tmp/CJ_python_test";
my $test_file = "\'$test_name\'";

my $python_check_script = <<PYTHON_CHECK;
test_fid = open($test_file,'w');
test_fid.write('test_passed');
test_fid.close();
PYTHON_CHECK

my $check_path = "/tmp";
my $check_name= "CJ_python_check_script.m";

&CJ::writeFile("$check_path/$check_name",$python_check_script);

my $junk = "/tmp/CJ_python.output";

my $python_check_bash = <<CHECK_BASH;
#!/bin/bash -l
python '$check_path/$check_name'  &>$junk;
CHECK_BASH



&CJ::message("Checking command 'python' is available...",1);
    
CJ::my_system("source ~/.bash_profile; source ~/.bashrc; printf '%s' $python_check_bash",$verbose);  # this will generate a file test_file

eval{
my $check = &CJ::readFile($test_name);     # this causes error if there is no file which indicates Python were not found.
    #print $check . "\n";
};
    
if($@){
#print $@ . "\n";
&CJ::err("CJ requires 'python' but it cannot access it. Check 'python' command.");
}else{
&CJ::message("python available.",1);
};


# build a script from top to output the range of index

# Add top
my $python_interpreter_script=$TOP;


# Add for lines
foreach my $i (0..$#{$for_lines}){
my $tag = $tag_list->[$i];
my $forline = $for_lines->[$i];
chomp($forline);
$forline = &CJ::remove_white_space($forline);
# print  "$tag: $forline\n";

my $tag_file = "\'/tmp/$tag\.tmp\'";
$python_interpreter_script .=<<PYTHON
$tag\_fid = open($tag_file,'w');
$forline
\t$tag\_fid.write(\"%i\\n\" \% $tag);
$tag\_fid.close();
PYTHON
}
my $name = "CJ_python_interpreter_script";
my $path = "/tmp";
&CJ::writeFile("$path/$name.py",$python_interpreter_script);
#&CJ::message("$name is built in $path",1);


my $python_interpreter_bash = <<BASH;
#!/bin/bash -l
# dump everything user-generated from top in /tmp
cd /tmp/
python <<HERE &>$junk;
import sys;
sys.path.append('$self->{path}');
sys.path.append('$self->{path}/$self->{dep_folder}');
import $name
HERE
BASH


&CJ::message("finding range of indices...",1);

CJ::my_system("source hatef.rc",$verbose);
CJ::my_system("source ~/.bash_profile",$verbose);
CJ::my_system("source ~/.profile",$verbose);
CJ::my_system("source ~/.bashrc",$verbose);
CJ::my_system("printf '%s' $python_interpreter_bash",$verbose);
    
&CJ::message("Closing Python session!",1);

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
&CJ::my_system("rm -f $test_name $junk $check_path/$check_name $path/$name.py");

return $range;

}


#####################
sub findIdxTagRange{
#####################
    
    my $self = shift;
    my ($parser,$verbose) = @_;
    
    my $FOR = $parser->{FOR};
    my $TOP = $parser->{TOP};
    
    # Determine the tags and ranges of the
    # indecies
    my @idx_tags;
    my $ranges={};  # This is a hashref $range->{tag}
    my @tags_to_python_interpret;
    my @forlines_to_python_interpret;
    
    
    my @forline_list = split /^/, $FOR;
    
    for my $this_forline (@forline_list) {
        
        my ($idx_tag, $range) = $self->read_python_index_set($this_forline, $TOP,$verbose);
        
        #FIX
        
        CJ::err("Index tag cannot be established for $this_forline") unless ($idx_tag);
        push @idx_tags, $idx_tag;   # This will keep order.
        
        if(defined($range)){
            $ranges->{$idx_tag} = $range;
        }else{
            push @tags_to_python_interpret, $idx_tag;
            push @forlines_to_python_interpret, $this_forline;
        }
        
    }
    
    
    if ( @tags_to_python_interpret ) { # if we need to run python
        my $range_run_interpret = $self->run_python_index_interpreter($TOP,\@tags_to_python_interpret,\@forlines_to_python_interpret, $verbose);
        
        
        for (keys %$range_run_interpret){
            $ranges->{$_} = $range_run_interpret->{$_};
            #print"$_:$range_run_interpret->{$_} \n";
        }
    }
    
    return (\@idx_tags,$ranges);
}




############################
sub uncomment_python_line{
############################
    my $self = shift;
    my ($line) = @_;
    # This uncomments useless comment lines.
    $line =~ s/^(?:(?![\"|\']).)*\K\#(.*)//;
    return $line;
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
    push @str , " $tag != $idx ";
}

my $str = join('or',@str);

my $INSERT = "if ($str): continue;";
my @BOT_lines = split /^/, $BOT;
my ($level) = $BOT_lines[0] =~ m/^(\s*).+/ ;  # determin our level of indentation
    
my $new_script = "$TOP\n$FOR\n$level$INSERT\n$BOT";
undef $INSERT;
return $new_script;
}






############################## UP TO HERE EDITED  FOR PY #####################

#############################
sub make_MAT_collect_script{
#############################
    
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



























##########################
sub check_initialization{
##########################
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




1;