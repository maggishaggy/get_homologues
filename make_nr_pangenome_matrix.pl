#!/usr/bin/perl -w

# 2016 Bruno Contreras-Moreira (1) and Pablo Vinuesa (2):
# 1: http://www.eead.csic.es/compbio (Laboratory of Computational Biology, EEAD/CSIC/Fundacion ARAID, Spain)
# 2: http://www.ccg.unam.mx/~vinuesa (Center for Genomic Sciences, UNAM, Mexico)

# This script computes a non-redundant pangenome matrix by comparing clusters with BLAST

# Takes as input the name of a pangenome matrix generated by compare_clusters.pl, other parameters 
# are documented when running the script without args or with -h option

$|=1;

use strict;
use Getopt::Std;
use File::Basename;
use File::Spec;
use FindBin '$Bin';
use lib "$Bin/lib";
use lib "$Bin/lib/bioperl-1.5.2_102/";
use phyTools; #imports constants SEQ,NAME used as array subindices
use marfil_homology;

## list of features/binaries required by this program (do not edit)
my @FEATURES2CHECK = ('EXE_BLASTP','EXE_BLASTN','EXE_FORMATDB','EXE_SPLITBLAST');

## settings for local batch blast jobs
my $BATCHSIZE = 100;
my $ONLYBESTREFHIT = 0; # take only best hit among reference hits

my ($INP_matrix,$INP_taxa,$INP_length,$INP_nucleotides,%opts) = ('',1,0,1);
my ($INP_identity,$INP_cover,$INP_reference_cover,$INP_reference_identity) = (90,75,50,50);
my ($INP_reference_cluster_dir,$INP_reference_file,$INP_use_short_sequence) = ('','',0);
my ($n_of_cpus) = ($BLAST_NOCPU);

getopts('hPes:c:f:r:n:t:m:l:C:S:', \%opts);

if(($opts{'h'})||(scalar(keys(%opts))==0))
{
  print   "\n[options]: \n";
  print   "-h \t this message\n";
  print   "-m \t input pangenome matrix .tab                                (required, made by compare_clusters.pl)\n"; 
  print   "-t \t consider only clusters with at least t taxa                (optional, default:$INP_taxa)\n";
  print   "-l \t min mean sequence length per cluster                       (optional, default:$INP_length)\n";
  print   "-S \t \%sequence identity cutoff                                  (optional, default:$INP_identity)\n";
  print   "-C \t \%alignment coverage cutoff                                 (optional, default:$INP_cover,\n";
  print   "   \t                                                             calculates coverage over longest sequence)\n";
  print   "-P \t sequences are peptides                                     (optional, by default expects nucleotides)\n"; 
  print   "-n \t number of threads for BLAST jobs                           (optional, default:$n_of_cpus)\n"; 
  print   "-e \t sequences are (probably) incomplete ESTs                   (optional, calculates coverage over shortest)\n";
  print   "\nParameters used to match input clusters to a reference:\n"; 
  print   "-r \t reference clusters contained in directory                  (optional, example: -r cross_species_clusters)\n"; 
  print   "-f \t parse sequences in this file                               (optional, ignores -r; example: -f swissprot.faa)\n"; 
  print   "-s \t \%sequence identity cutoff for matching reference seqs      (optional, default:$INP_reference_identity)\n";
  print   "-c \t \%alignment coverage cutoff for matching reference seqs     (optional, default:$INP_reference_cover,\n";
  print   "   \t                                                             calculates coverage over longest sequence)\n";
  exit(-1);
}

print check_installed_features(@FEATURES2CHECK);

if(defined($opts{'m'})){ $INP_matrix = $opts{'m'} }
else{ die "\n# $0 : need -m parameter, exit\n"; }

if(defined($opts{'t'}) && $opts{'t'} > 0)
{
  $INP_taxa = $opts{'t'};
}

if(defined($opts{'l'}) && $opts{'l'} > 0)
{
  $INP_length = $opts{'l'};
}

if(defined($opts{'C'}) && $opts{'C'} > 0 && $opts{'C'} <= 100)
{
  $INP_cover = $opts{'C'};
}

if(defined($opts{'S'}) && $opts{'S'} > 0 && $opts{'S'} <= 100)
{
  $INP_identity = $opts{'S'};
}

if(defined($opts{'P'}))
{
  $INP_nucleotides = 0;
}

if(defined($opts{'n'}) && $opts{'n'} > 0)
{
  $n_of_cpus = int($opts{'n'});
  $BLAST_NOCPU = $n_of_cpus;
}

if(defined($opts{'f'}) || defined($opts{'r'}))
{
  if($opts{'f'} && -s $opts{'f'}){ $INP_reference_file = $opts{'f'} }
  elsif(defined($opts{'r'}) && -d $opts{'r'}){ $INP_reference_cluster_dir = $opts{'r'} }
  else
  {
    print "\n# ignoring reference...\n\n";
  }
  
  if(defined($opts{'c'}) && $opts{'c'} > 0 && $opts{'c'} <= 100)
  {
    $INP_reference_cover = $opts{'c'};
  }
  if(defined($opts{'s'}) && $opts{'s'} > 0 && $opts{'s'} <= 100)
  {
    $INP_reference_identity = $opts{'s'};
  }
}  

if(defined($opts{'e'}))
{
  $INP_use_short_sequence = 1;
}

print "\n# ONLYBESTREFHIT=$ONLYBESTREFHIT\n";
printf("\n# %s -m %s -t %d -l %d -C %d -S %d -P %s -f %s -r %s -c %d -s %d -e %d -n %d\n\n",
	$0,$INP_matrix,$INP_taxa,$INP_length,$INP_cover,$INP_identity,!$INP_nucleotides,
  $INP_reference_file,$INP_reference_cluster_dir,
  $INP_reference_cover,$INP_reference_identity,
  $INP_use_short_sequence,$n_of_cpus);

#################################### MAIN PROGRAM  ################################################

my (@cluster_names,@header,@taxa,@length,@filtered,@median_seq,@id2name,@trash);
my (%pangemat,%redundant,%nr,%clust2col,%median_length,%matched_clusters,%ref_match);
my ($n_of_clusters,$filtered_clusters,$merged_clusters,$taxon,$cluster_name,$command) = (0,0,0);
my ($col2,$seq,$size,$median,$l,$col,$cluster_dir,$red_name,$pQcov,$pScov);
my ($pQid,$querylen,$pSid,$subjectlen,$pEvalue,$ppercID,$simspan,$pbits,$cover);

my $outfile_root = $INP_matrix; $outfile_root =~ s/\.tab//g;

$outfile_root .= "_nr_t$INP_taxa\_l$INP_length\_e$INP_use_short_sequence\_C$INP_cover\_S$INP_identity";

my $nr_pangenome_fasta_file = $outfile_root;
my $nr_pangenome_blast_file = $outfile_root . '.blast';
my $nr_pangenome_bpo_file = $outfile_root . '.bpo';
my $nr_pangenome_file = $outfile_root.'.tab';

if($INP_reference_file || $INP_reference_cluster_dir)
{ 
  $nr_pangenome_file = $outfile_root."_ref_c$INP_reference_cover\_s$INP_reference_identity.tab";
}

my ($nr_pangenome_reference_fasta_file,$nr_pangenome_reference_blast_file);
my ($nr_pangenome_reference_bpo_file,$nr_pangenome_tmp_fasta_file);

if($INP_nucleotides)
{ 
  $nr_pangenome_fasta_file .= '.fna'; 
  push(@trash,$nr_pangenome_fasta_file.'.nhr',
    $nr_pangenome_fasta_file.'.nin',
    $nr_pangenome_fasta_file.'.nsq');
}
else
{ 
  $nr_pangenome_fasta_file .= '.faa'; 
  push(@trash,$nr_pangenome_fasta_file.'.phr',
    $nr_pangenome_fasta_file.'.pin',
    $nr_pangenome_fasta_file.'.psq');
}

unlink($nr_pangenome_fasta_file,$nr_pangenome_file);

## 1) parse pangenome matrix
open(MAT,$INP_matrix) || die "# EXIT : cannot read $INP_matrix\n";
while(<MAT>)
{
  next if(/^#/ || /^$/);
  chomp;
  my @data = split(/\t/,$_);
  if($data[0] =~ /^source:(\S+)/) #source:path/to/clusters/t101964_thrB.fna/t101965_thrC.fna/t...
  {
    $cluster_dir = $1;
    foreach $col (1 .. $#data){ $cluster_names[$col] = $data[$col] }
    $n_of_clusters = $#data;
  }
  else #_Escherichia_coli_ETEC_H10407_uid42749.gbk     1       1	...
  {
    if(!grep(/^$data[0]$/,@taxa)){ push(@taxa,$data[0]) }
  
    foreach $col (1 .. $#data)
    {
      $pangemat{$data[0]}[$col] = $data[$col];
    }
  }
}
close(MAT);
print "# input matrix contains $n_of_clusters clusters and ".scalar(keys(%pangemat))." taxa\n";



## 2) filter clusters by median sequence length
print "\n# filtering clusters ...\n";
foreach $col (1 .. $n_of_clusters)
{
  my ($present_taxa) = (0);
  foreach $taxon (@taxa)
  {
    if($pangemat{$taxon}[$col]){ $present_taxa++ }
  }

  next if($present_taxa < $INP_taxa);
  
  # calculate median length of cluster sequences
  $size = 0;
  $cluster_name = $cluster_names[$col];
  my $fasta_ref = read_FASTA_file_array( $cluster_dir.'/'.$cluster_name );
  if(!@$fasta_ref){ die "# ERROR: could not read $cluster_dir/$cluster_name, please check your matrix and the path to clusters therein\n" }
  my @cluster_l;
 
  foreach $seq ( 0 .. $#{$fasta_ref} )
  {
    if($INP_nucleotides && $fasta_ref->[$seq][SEQ] =~ /^[^ACGTWSRYKMXN\-\s]+$/i)
    {
      print "# ERROR: cluster $cluster_dir/$cluster_name contains protein sequences, exit\n";
      exit;
    }
        
    push(@cluster_l,length($fasta_ref->[$seq][SEQ]));
    $size++;
  }
  
  @cluster_l = sort {$a<=>$b} @cluster_l;
  $median = $cluster_l[int($size/2)];
  
  foreach $seq ( 0 .. $#{$fasta_ref} )
  {
    $l = length($fasta_ref->[$seq][SEQ]);
    if($l == $median)
    {
      $median_seq[$col] = $fasta_ref->[$seq][SEQ];
      $header[$col] = $fasta_ref->[$seq][NAME];
      $length[$col] = $l;
      print "# cluster $col\r"; 
      last;
    }
  }
  
  next if($length[$col] < $INP_length);
    
  $filtered_clusters++;
  push(@filtered,$col);
}  
print "# $filtered_clusters clusters with taxa >= $INP_taxa and sequence length >= $INP_length\n";



## 3) sort clusters by length, number them and get representative sequence from each (the middle-length one)
print "\n# sorting clusters and extracting median sequence ...\n";
$filtered_clusters = 0;

open(FASTA,">$nr_pangenome_fasta_file") || die "# ERROR : cannot create $nr_pangenome_fasta_file\n";
foreach $col (sort {$length[$b] <=> $length[$a]} @filtered)
{
  $filtered_clusters++;
  $clust2col{$filtered_clusters} = $col;

  print FASTA ">$filtered_clusters $col $cluster_names[$col]\n$median_seq[$col]\n";
  $median_length{$filtered_clusters} = $length[$col];
}  
close(FASTA); 



## 4) format cluster sequences and run BLAST if required
if(!-s $nr_pangenome_blast_file)
{
  if($INP_nucleotides)
  { 
    executeFORMATDB($nr_pangenome_fasta_file,1);
    if(!-s $nr_pangenome_fasta_file . '.nsq')
    {
      die "# EXIT: cannot format BLAST nucleotide sequence base $nr_pangenome_fasta_file\n";
    }
    
    $command = format_BLASTN_command($nr_pangenome_fasta_file,$nr_pangenome_blast_file,
      $nr_pangenome_fasta_file,$BLAST_PVALUE_CUTOFF_DEFAULT,2,1,'megablast');
  }
  else
  { 
    executeFORMATDB($nr_pangenome_fasta_file);
    if(!-s $nr_pangenome_fasta_file . '.psq')
    {
      die "# EXIT: cannot format BLAST protein sequence base $nr_pangenome_fasta_file\n";
    }
    
    $command = format_BLASTP_command($nr_pangenome_fasta_file,$nr_pangenome_blast_file,
      $nr_pangenome_fasta_file,$BLAST_PVALUE_CUTOFF_DEFAULT,2,1);
  }  
  
  $command = format_SPLITBLAST_command()."$BATCHSIZE $command > /dev/null"; 
  system("$command");
  if($? != 0)
  {
    die "# EXIT: failed while running BLAST search ($command)\n";
  }
}
else
{
  print "# re-using previous BLAST output $nr_pangenome_blast_file\n";
}


## 5) merge clusters based on BLAST similarities
blast_parse($nr_pangenome_blast_file,$nr_pangenome_bpo_file,\%median_length,$BLAST_PVALUE_CUTOFF_DEFAULT,1);

unlink($nr_pangenome_fasta_file);

open(BPO,$nr_pangenome_bpo_file) || die "# ERROR : cannot find $nr_pangenome_bpo_file, cannot proceed\n";
while(<BPO>)
{
  #$similarityid;$pQid;$querylen;$pSid;$subjectlen;$pEvalue;$ppercID;$simspan;$pbits
  #16;2;274;37937;274;1e-103;66;1:5-272:6-274.;375
  #313	313	100.00	291	0	0	1	291	1	291	0.0	 590
  #313	93	26.69	236	166	4	40	273	279	509	6e-21	95.5
  #($hit,$pQid,$querylen,$pSid,$subjectlen,$pEvalue,$ppercID,$simspan,$pbits) = split(/;/,$_);
  ($pQid,$pSid,$pEvalue,$ppercID,$pQcov,$pScov,$querylen,$subjectlen,$simspan,$pbits) = split(/\t/,$_);
  
  # redundant cluster are $pQid > $pSid
  next if($pQid eq $pSid || $pQid < $pSid);
  
  next if($ppercID < $INP_identity);
  
  #$cover = simspan_hsps($querylen,$subjectlen,$simspan,$INP_use_short_sequence);
  
  if($INP_use_short_sequence)
  {
    if($querylen < $subjectlen){ $cover = $pQcov }
    else{ $cover = $pScov }
  }
  else
  {
    if($querylen > $subjectlen){ $cover = $pQcov }
    else{ $cover = $pScov }
  }
  
  if($cover >= $INP_cover) 
  {
    # record parent cluster and merge
    $redundant{$clust2col{$pQid}}++;
    push(@{$nr{$clust2col{$pSid}}},$clust2col{$pQid}); 
  }
}
close(BPO);

open(NR,">$nr_pangenome_fasta_file") || die "# ERROR : cannot create $nr_pangenome_fasta_file\n";
#foreach $col (sort {$length[$b] <=> $length[$a]} @filtered)
foreach $col (@filtered)
{
  next if($redundant{$col}); 
  print NR ">$cluster_names[$col] $header[$col]\n$median_seq[$col]\n";
  $merged_clusters++;
}  
close(NR);	
 
print "\n# $merged_clusters non-redundant clusters\n";
print "# created: $nr_pangenome_fasta_file\n";

## 6) if required match nr clusters to external reference sequences
if($INP_reference_file || $INP_reference_cluster_dir)
{
  my ($ref_cluster_id,$id,$n_of_ref_sequences);
  my (@ref_clusterfiles,%ref_length,%ref_seen,@ref_cluster_size); 
  
  $nr_pangenome_reference_fasta_file = $outfile_root;
  $nr_pangenome_reference_blast_file = $outfile_root.'_ref.blast';
  $nr_pangenome_reference_bpo_file   = $outfile_root.'_ref.bpo';
  $nr_pangenome_tmp_fasta_file       = $outfile_root.'_nr';
  
  if($INP_reference_file) # reference sequences in a single FASTA file
  {
    if($INP_nucleotides)
    {
      $nr_pangenome_reference_fasta_file .= '_ref.fna'; 
      $nr_pangenome_tmp_fasta_file .= '.fna'; 
      push(@trash,$nr_pangenome_reference_fasta_file.'.nhr',
        $nr_pangenome_reference_fasta_file.'.nin',
        $nr_pangenome_reference_fasta_file.'.nsq');
    }
    else
    {
      $nr_pangenome_reference_fasta_file .= '_ref.faa'; 
      $nr_pangenome_tmp_fasta_file .= '.faa'; 
      push(@trash,$nr_pangenome_reference_fasta_file.'.phr',
        $nr_pangenome_reference_fasta_file.'.pin',
        $nr_pangenome_reference_fasta_file.'.psq');
    }
    
    # save reference sequences in a single FASTA file to be scanned by BLAST  
    open(REF,">$nr_pangenome_reference_fasta_file") || die "# ERROR : cannot create $nr_pangenome_reference_fasta_file\n";
    $ref_cluster_id = $n_of_ref_sequences = 0;
    my $fasta_ref = read_FASTA_file_array($INP_reference_file);
    foreach $seq ( 0 .. $#{$fasta_ref} )
    {
      $id = $ref_cluster_id.'_'.$n_of_ref_sequences;
      print REF ">$id $fasta_ref->[$seq][NAME]\n$fasta_ref->[$seq][SEQ]\n";
      
      # check nr sequences and reference sequences are compatible
      if( ($INP_nucleotides && $fasta_ref->[$seq][SEQ] =~ m/[PDEQHILVF]/) ||
        (!$INP_nucleotides && $fasta_ref->[$seq][SEQ] !~ m/[PDEQHILVF]/) )
      {
        print "# both input clusters and references must be either nucleotides or peptides\n";
        print "# offending sequence: \n$fasta_ref->[$seq][SEQ]\n";
        exit;
      }
      
      $ref_length{$id} = length($fasta_ref->[$seq][SEQ]);
      $ref_cluster_size[$ref_cluster_id] = 1;
      $id2name[$ref_cluster_id] = $fasta_ref->[$seq][NAME]; 
      #print "$ref_cluster_id $fasta_ref->[$seq][NAME]\n"; 66321 ChrSy.fgenesh.mRNA.73 cDNA|expressed protein
      $n_of_ref_sequences++;
      $ref_cluster_id++;
    }  
    close(REF); 
    
    if(!$n_of_ref_sequences++)
    {
      die "# EXIT : cannot parse sequences in $INP_reference_file\n";
    }
    else
    {
      printf("\n# %d reference sequences parsed in %s\n",$n_of_ref_sequences,$INP_reference_file);
    } 
    
    # create a temporary FASTA file with the previosuly computed nr cluster sequences
    open(NR,">$nr_pangenome_tmp_fasta_file") || die "# ERROR : cannot create $nr_pangenome_tmp_fasta_file\n";
    foreach $col (@filtered)
    {
      next if($redundant{$col}); 
      print NR ">$col\_$cluster_names[$col]\n$median_seq[$col]\n";
    }  
    close(NR);	
  }
  elsif($INP_reference_cluster_dir) # pre-built reference clusters, each in one FASTA file
  {
    opendir(CLDIR,$INP_reference_cluster_dir) || die "# EXIT : cannot list $INP_reference_cluster_dir\n";
  
    if($INP_nucleotides)
    {
      @ref_clusterfiles = sort grep {/\.fna$/i} readdir(CLDIR);
      $nr_pangenome_reference_fasta_file .= '_ref.fna'; 
      $nr_pangenome_tmp_fasta_file .= '.fna'; 
      push(@trash,$nr_pangenome_reference_fasta_file.'.nhr',
        $nr_pangenome_reference_fasta_file.'.nin',
        $nr_pangenome_reference_fasta_file.'.nsq');
    }
    else
    {
      @ref_clusterfiles = sort grep {/\.faa$/i} readdir(CLDIR);
      $nr_pangenome_reference_fasta_file .= '_ref.faa'; 
      $nr_pangenome_tmp_fasta_file .= '.faa'; 
      push(@trash,$nr_pangenome_reference_fasta_file.'.phr',
        $nr_pangenome_reference_fasta_file.'.pin',
        $nr_pangenome_reference_fasta_file.'.psq');
    }
 
    closedir(CLDIR);
  
    if(!@ref_clusterfiles)
    {
      die "# EXIT : cannot find .fna/.faa files in $INP_reference_cluster_dir\n";
    }
    else
    {
      printf("\n# %d reference clusters found in %s\n",scalar(@ref_clusterfiles),$INP_reference_cluster_dir);
    } 
  
    # save all reference cluster sequences in a single FASTA file to be scanned by BLAST  
    open(REF,">$nr_pangenome_reference_fasta_file") || die "# ERROR : cannot create $nr_pangenome_reference_fasta_file\n";
    $ref_cluster_id = $n_of_ref_sequences = 0;
    foreach my $clusterfile (@ref_clusterfiles)
    {
      my $fasta_ref = read_FASTA_file_array($INP_reference_cluster_dir.'/'.$clusterfile);
      foreach $seq ( 0 .. $#{$fasta_ref} )
      {
        $id = $ref_cluster_id.'_'.$n_of_ref_sequences;
        print REF ">$id $clusterfile $fasta_ref->[$seq][NAME]\n$fasta_ref->[$seq][SEQ]\n"; # might cause trouble with BLAST
        print REF ">$id $clusterfile\n$fasta_ref->[$seq][SEQ]\n";
        
        # check nr sequences and reference sequences are compatible
        if( ($INP_nucleotides && $fasta_ref->[$seq][SEQ] =~ m/[PDEQHILVF]/) ||
          (!$INP_nucleotides && $fasta_ref->[$seq][SEQ] !~ m/[PDEQHILVF]/) )
        {
          print "# both input clusters and references must be either nucleotides or peptides\n";
          print "# offending sequence: \n$fasta_ref->[$seq][SEQ]\n";
          exit;
        }
        
        $ref_length{$id} = length($fasta_ref->[$seq][SEQ]);
        $n_of_ref_sequences++;
        $ref_cluster_size[$ref_cluster_id]++;
      }  
      $id2name[$ref_cluster_id] = $clusterfile;
      $ref_cluster_id++;
    }    
    close(REF);
    
    # create a temporary FASTA file with the previously computed nr cluster sequences
    open(NR,">$nr_pangenome_tmp_fasta_file") || die "# ERROR : cannot create $nr_pangenome_tmp_fasta_file\n";
    foreach $col (@filtered)
    {
      next if($redundant{$col}); 
      print NR ">$col $cluster_names[$col]\n$median_seq[$col]\n";
    }  
    close(NR);	
  }   
      
  # run BLAST
  if(!-s $nr_pangenome_reference_blast_file)
  {
    if($INP_nucleotides) # nucl to nucl
    { 
      executeFORMATDB($nr_pangenome_reference_fasta_file,1);
      if(!-s $nr_pangenome_reference_fasta_file . '.nsq')
      {
        die "# EXIT: cannot format BLAST nucleotide sequence base $nr_pangenome_reference_fasta_file\n";
      }
    
      $command = format_BLASTN_command($nr_pangenome_tmp_fasta_file,$nr_pangenome_reference_blast_file,
        $nr_pangenome_reference_fasta_file,$BLAST_PVALUE_CUTOFF_DEFAULT,500,1,'megablast');
    }
    else # prot to prot
    { 
      executeFORMATDB($nr_pangenome_reference_fasta_file);
      if(!-s $nr_pangenome_reference_fasta_file . '.psq')
      {
        die "# EXIT: cannot format BLAST peptide sequence base $nr_pangenome_reference_fasta_file\n";
      }
    
      $command = format_BLASTP_command($nr_pangenome_tmp_fasta_file,$nr_pangenome_reference_blast_file,
        $nr_pangenome_reference_fasta_file,$BLAST_PVALUE_CUTOFF_DEFAULT,500,1);
    }  
  
    $command = format_SPLITBLAST_command()."$BATCHSIZE $command > /dev/null"; #die $command;
    system("$command");
    if($? != 0)
    {
      die "# EXIT: failed while running BLAST search ($command)\n";
    }
  }
  else
  {
    print "# re-using previous BLAST output $nr_pangenome_reference_blast_file\n";
  }

  blast_parse($nr_pangenome_reference_blast_file,$nr_pangenome_reference_bpo_file,\%ref_length,$BLAST_PVALUE_CUTOFF_DEFAULT,1);

  print "\n# matching nr clusters to reference (\%alignment coverage cutoff=$INP_reference_cover) ...\n";
  open(BPO,$nr_pangenome_reference_bpo_file) || die "# ERROR : cannot find $nr_pangenome_reference_bpo_file, cannot proceed\n";
  while(<BPO>)
  {
    # col -> nr sequence, actually a column of the pangenome matrix
    # pSid -> reference sequence
    # 1,49439_49439
    ($col,$pSid,$pEvalue,$ppercID,$pQcov,$pScov,$querylen,$subjectlen,$simspan,$pbits) = split(/\t/,$_);
    #print if($col eq '890'); # debugging

    next if($ref_match{$col} && $ONLYBESTREFHIT); 
  
    #$cover = simspan_hsps($querylen,$subjectlen,$simspan,0);    
    if($INP_use_short_sequence)
    {
      if($querylen < $subjectlen){ $cover = $pQcov }
      else{ $cover = $pScov }
    }
    else
    {
      if($querylen > $subjectlen){ $cover = $pQcov }
      else{ $cover = $pScov }
    }
    
    if($cover >= $INP_reference_cover && $ppercID >= $INP_reference_identity) 
    {
      $ref_cluster_id = (split(/_/,$pSid))[0]; #print "$pQid $pSid $ref_cluster_id $cover\n";

      next if($ref_seen{$ref_cluster_id}{$col});

      $ref_match{$col} .= "$ref_cluster_id,"; 
      $ref_seen{$ref_cluster_id}{$col}=1;
      
      # add this cluster sequences' to the right pangenome matrix column
      $matched_clusters{$col} += $ref_cluster_size[$ref_cluster_id];
    }
  }
  close(BPO);

  printf("# %d nr clusters matched by %d reference sequences/clusters\n\n",
    scalar(keys(%matched_clusters)),scalar(keys(%ref_seen)));
}

## 7) print nr pangenome matrix
print "\n# printing nr pangenome matrix ...\n";
open(NRMAT,">$nr_pangenome_file");
print NRMAT "non-redundant";
foreach $col (@filtered)
{
  next if($redundant{$col});
  $cluster_name = $cluster_names[$col]; 
  if($nr{$col})
  { 
    $cluster_name .= '+'.scalar(@{$nr{$col}});
  }
  print NRMAT "\t$cluster_name";
} print NRMAT "\t\n";

foreach $taxon (@taxa)
{
  print NRMAT "$taxon";
  foreach $col (@filtered)
  {
    next if($redundant{$col});
    $size = $pangemat{$taxon}[$col];
    if($nr{$col})
    { 
      foreach $col2 (@{$nr{$col}}){ $size += $pangemat{$taxon}[$col2] }
    }
    print NRMAT "\t$size";
  } print NRMAT "\t\n";
} 

# add reference clusters row if required
if($INP_reference_cluster_dir)
{
  print NRMAT "reference:$INP_reference_cluster_dir";
  foreach $col (@filtered)
  {
    next if($redundant{$col});
    $size = $matched_clusters{$col} || 0; 
    print NRMAT "\t$size";
  } print NRMAT "\t\n";
}

print NRMAT "redundant";
foreach $col (@filtered)
{
  next if($redundant{$col});
  if($nr{$col})
  {
    $red_name = $cluster_names[$col];
    foreach $col2 (@{$nr{$col}}){ $red_name .= ",$cluster_names[$col2]" }
  }
  else{ $red_name = 'NA' }
  print NRMAT "\t$red_name";
} print NRMAT "\t\n";

# add reference clusters row of additional data if required
if($INP_reference_file || $INP_reference_cluster_dir)
{
  print NRMAT "reference";
  foreach $col (@filtered)
  {
    next if($redundant{$col});
    $cluster_name = '';
    if($matched_clusters{$col})
    {
      foreach my $cl (split(/,/,$ref_match{$col}))
      {    
        $cluster_name .= "$id2name[$cl],";
      }  
    }
    else{ $cluster_name = 'NA' }  
   
    print NRMAT "\t$cluster_name";
  } print NRMAT "\t\n";
}

close(NRMAT);

print "# created: $nr_pangenome_file\n";

print "\n# NOTE: matrix can be transposed for your convenience with:\n\n";
  
print <<'TRANS';
  perl -F'\t' -ane '$r++;for(1 .. @F){$m[$r][$_]=$F[$_-1]};$mx=@F;END{for(1 .. $mx){for $t(1 .. $r){print"$m[$t][$_]\t"}print"\n"}}' \
TRANS

  print "   $nr_pangenome_file\n";

## 8) clean tmp blast files (comment while debugging)
unlink($nr_pangenome_bpo_file,@trash);
if($INP_reference_cluster_dir)
{
  unlink($nr_pangenome_reference_fasta_file,$nr_pangenome_reference_bpo_file,$nr_pangenome_tmp_fasta_file);
}    
