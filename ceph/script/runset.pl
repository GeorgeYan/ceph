#!/usr/bin/perl

use strict;
use Data::Dumper;

=item sample input file

# hi there
{
	# startup
	'n' => 30,          # mpi nodes
	'sleep' => 10,      # seconds between runs
	'nummds' => 1,
	'numosd' => 8,
	'numclient' => 400,#[10, 50, 100, 200, 400],

	# parameters
	'fs' => [ 'ebofs', 'fakestore' ],
	'until' => 150,     # --syn until $n    ... when to stop clients
	'writefile' => 1,
	'writefile_size' => [ 4096, 65526, 256000, 1024000, 2560000 ],
	'writefile_mb' => 1000,

	'custom' => '--tcp_skip_rank0 --osd_maxthreads 0';

	# for final summation (script/sum.pl)
	'start' => 30,
	'end' => 120,

	'_psub' => 'alc.tp'   # switch to psub mode!
};

=cut

my $usage = "script/runset.pl [--clean] jobs/some/job blah\n";

my $clean;
my $in = shift || die $usage;
if ($in eq '--clean') {
	$clean = 1;
	$in = shift | die $usage;
}
my $tag = shift || die $usage;
my $fake = shift;


my ($job) = $in =~ /^jobs\/(.*)/;
my ($jname) = $job =~ /\/(\w+)$/;
$jname ||= $job;
die "not jobs/?" unless defined $job;
my $out = "log/$job.$tag";
my $relout = "$job.$tag";


my $cwd = `/bin/pwd`;
chomp($cwd);



print "# --- job $job, tag $tag ---\n";


# get input
my $raw = `cat $in`;
my $sim = eval $raw;
unless (ref $sim) {
	print "bad input: $in\n";
	system "perl -c $in";
	exit 1;
}

open(W, "$out/in");
print W $raw;
close W;

my $comb = $sim->{'comb'};
delete $sim->{'comb'};
my %filters;
my @fulldirs;

# prep output
system "mkdir -p $out" unless -d "$out";


sub reset {
	print "reset: restarting mpd in 3 seconds\n";
	system "sleep 3 && (mpiexec -l -n 32 killall tcpsyn ; restartmpd.sh)";
	print "reset: done\n";
}

if (`hostname` =~ /alc/) {
	print "# this looks like alc\n";
	$sim->{'_psub'} = 'jobs/alc.tp';
}


sub iterate {
	my $sim = shift @_;
	my $fix = shift @_ || {};
	my $vary;
	my @r;

	my $this;
	for my $k (sort keys %$sim) {
		next if $k =~ /^_/;
		if (defined $fix->{$k}) {
			$this->{$k} = $fix->{$k};
		}
		elsif (ref $sim->{$k} eq 'HASH') {
			# nothing
		}
		elsif (!(ref $sim->{$k})) {
			$this->{$k} = $sim->{$k};
		}
		else {
			#print ref $sim->{$k};
			if (!(defined $vary)) {
				$vary = $k;
			}
		}
	}

	if ($vary) {
		#print "vary $vary\n";
		for my $v (@{$sim->{$vary}}) {
			$this->{$vary} = $v;
			push(@r, &iterate($sim, $this));
		}
	} else {

		if ($sim->{'_dep'}) {
			my @s = @{$sim->{'_dep'}};
			while (@s) {
				my $dv = shift @s;
				my $eq = shift @s;

				$eq =~ s/\$(\w+)/"\$this->{'$1'}"/eg;
				$this->{$dv} = eval $eq;
				#print "$dv : $eq -> $this->{$dv}\n";
			}
		}

		push(@r, $this);
	}
	return @r;
}

sub run {
	my $h = shift @_;

	my @fn;
	my @filt;
	my @vals;
	for my $k (sort keys %$sim) {
		next if $k =~ /^_/;
		next unless ref $sim->{$k} eq 'ARRAY';
		push(@fn, "$k=$h->{$k}");
		push(@vals, $h->{$k});
		next if $comb && $k eq $comb->{'x'};
		push(@filt, "$k=$h->{$k}");
	}
	my $keys = join(",", @fn);
	$keys =~ s/ /_/g;
	my $fn = $out . '/' . $keys;
	my $name = $jname . '_' . join('_',@vals); #$tag . '_' . $keys;

	push( @fulldirs, "" . $fn );

	
	# filters
	$filters{ join(',', @filt) } = 1;


	if (-e "$fn/.done") {
		print "already done.\n";
		system "sh $fn/sh.post" if -e "$fn/sh.post";# && !(-e "$fn/.post");
		return;
	}
	system "rm -r $fn" if $clean && -d "$fn";
	system "mkdir $fn" unless -d "$fn";

	my $e = './tcpsyn';
	$e = './tcpsynobfs' if $h->{'fs'} eq 'obfs';
	my $c = "$e --mkfs";
	$c .= " --$h->{'fs'}";
	$c .= " --syn until $h->{'until'}" if $h->{'until'};

	$c .= " --syn writefile $h->{'writefile_mb'} $h->{'writefile_size'}" if $h->{'writefile'};
	$c .= " --syn makedirs $h->{'makedirs_dirs'} $h->{'makedirs_files'} $h->{'makedirs_depth'}" if $h->{'makedirs'};

	for my $k ('nummds', 'numclient', 'numosd', 'kill_after',
			   'osd_maxthreads', 'osd_object_layout', 'osd_pg_layout','osd_pg_bits',
			   'mds_bal_rep', 'mds_bal_interval', 'mds_bal_max','mds_decay_halflife',
			   'mds_bal_hash_rd','mds_bal_hash_wr','mds_bal_unhash_rd','mds_bal_unhash_wr',
			   'bdev_el_bidir', 'ebofs_idle_commit_ms', 'ebofs_commit_ms', 
			   'ebofs_oc_size','ebofs_cc_size','ebofs_bc_size','ebofs_bc_max_dirty','ebofs_abp_max_alloc',
			   'file_layout_ssize','file_layout_scount','file_layout_osize','file_layout_num_rep',
			   'meta_dir_layout_ssize','meta_dir_layout_scount','meta_dir_layout_osize','meta_dir_layout_num_rep',
			   'meta_log_layout_ssize','meta_log_layout_scount','meta_log_layout_osize','meta_log_layout_num_rep') {
		$c .= " --$k $h->{$k}" if defined $h->{$k};
	}

	$c .= ' ' . $h->{'custom'} if $h->{'custom'};

	$c .= " --log_name $relout/$keys";

	my $post = "#!/bin/sh
script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/osd?? > $fn/sum.osd
script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/mds? $fn/mds?? > $fn/sum.mds
test -e $fn/clnode.1 && script/sum.pl -start $h->{'start'} -end $h->{'end'} $fn/clnode* > $fn/sum.cl
touch $fn/.post
";
	open(O,">$fn/sh.post");
	print O $post;
	close O;

	my $killmin = 1 + $h->{'kill_after'} / 60;
	my $srun = "srun -l -t $killmin -N $h->{'n'} -p ltest $c > $fn/o && touch $fn/.done
";
	open(O,">$fn/sh.srun");
	print O $srun;
	close O;
	
	if ($sim->{'_psub'}) {
		# template!
		my $tp = `cat $sim->{'_psub'}`;
		$tp =~ s/\$CWD/$cwd/g;
		$tp =~ s/\$NAME/$name/g;
		$tp =~ s/\$NUM/$h->{'n'}/g;
		$tp =~ s/\$OUT/$fn\/o/g;
		$tp =~ s/\$DONE/$fn\/.done/g;
		$tp =~ s/\$CMD/$c/g;
		open(O,">$out/$name");
		print O $tp;
		close O;
		print "\npsub $out/$name\n";
		return;
	} else {
		# run
		my $l = "mpiexec -l -n $h->{'n'}";
		print "-> $l $c\n";
		my $r = 0;
		unless ($fake) {
			$r = system "$l $c > $fn/o";
			if ($r) {
				print "r = $r\n";
				&reset;
			} else {
				system "touch $fn/.done";
			}
			system "sh $fn/sh.post";
		}
		return $r;
	}
}



my @r = &iterate($sim);
my $n = scalar(@r);
my $c = 1;
my %r;
my $nfailed = 0;
for my $h (@r) {
	my $d = `date`;
	chomp($d);
	$d =~ s/ P.T .*//;
	print "# === $c/$n";
	print " ($nfailed failed)" if $nfailed;
	print " $d: ";
	my $r = &run($h);

	if (!(defined $r)) {
		# already done
	} else {
		if ($r) {
			$nfailed++;
		}
		print "sleep $h->{'sleep'}\n";
		sleep $h->{'sleep'};
	}

	$c++;
}
print "$nfailed failed\n";


my @comb;
if ($comb) {
	my $x = $comb->{'x'};
	my @vars = @{$comb->{'vars'}};

	my @filters = sort keys %filters;
	my $cmd = "script/comb.pl $x @vars - @fulldirs - @filters > $out/c";
	print "\n$cmd\n";
	open(O,">$out/comb");
	print O "$cmd\n";
	close O;
	system $cmd;

	my $plot;
	$plot .= "set data style linespoints;\n";
	my $s = 2;
	for my $v (@vars) {
		my $c = $s;
		$s++;
		my @p;
		for my $f (@filters) {
			my $t = $f;
			if ($comb->{'maptitle'}) {
				for my $a (keys %{$comb->{'maptitle'}}) {
					my $b = $comb->{'maptitle'}->{$a};
					$t =~ s/$a/$b/;
				}
			}
			push (@p, "\"$out/c\" u 1:$c t \"$t\"" );
			$c += scalar(@vars);
		}
		$plot .= "# $v\nplot " . join(", ", @p) . ";\n\n";
	}
	print $plot;
	open(O,">$out/plot");
	print O $plot;
	close O;
}

