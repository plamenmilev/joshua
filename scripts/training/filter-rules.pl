#!/usr/bin/env perl
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Removes rules from phrase tables and grammars according to various criteria.
#
# October 2016. It turns out that Thrax keeps *all* rules it finds for each source
# side. In big bitexts, this can mean that common words collect tens or even hundreds
# of thousands of translation options, due to garbage collection (Moore, 2004), all of
# which are then retained. These can be filtered out by this script, which will reduce
# the grammar to contain only the top 100 translation options (by count) for each source
# side. This only works for grammars that have a 6th |||-delimited field containing
# rule counts:
#
#   gzip -cd grammar.gz | filter-rules.pl -t 100 | gzip -9n > grammar-filtered.gz
#
# If you don't have that field, but do have a tuned model, you can also filter by using that,
# say after tuning:
#
#   gzip -cd grammar.gz | filter-rules.pl -t 100 -c /path/to/joshua.config -o pt ...
#
# Really this should all just be built into thrax.

use strict;
use warnings;
use List::Util qw/max sum/;
use Getopt::Std;

my %opts = ();
my $ret = getopts("bps:uvc:t:o:f:", \%opts);

if (!$ret) {
  print "Usage: filter-rules.pl [-u] [-s SCOPE] [-v]\n";
  print "   -b: skip blank source and target sides\n";
  print "   -p: just print the rule's scope\n";
  print "   -s SCOPE: remove rules with scope > SCOPE (Hopkins & Langmead, 2010)\n";
  print "   -u: remove abstract unary rules\n";
  print "   -v: be verbose\n";
  print "   -t: only include top N candidates\n";
  print "   -c: path to joshua config file\n";
  print "   -o: grammar owner (required for -t)\n";
  exit;
}

my ($total) = (0, 0);
my %SKIPPED = (
  unary => 0,
  lex_scope => 0,
  unlex_scope => 0,
  redundant => 0,
);


my %WEIGHTS = ($opts{c}) ? read_weights($opts{c}) : ();
  
my $prev_source = "";
my @lines;
while (my $line = <>) {
  my ($source, $target);
  if ($line =~ /^\[/) {
    # hierarchical grammars
    (undef, $source, $target) = split(/ \|\|\| /, $line);
  } else {
    # phrase table
    ($source, $target) = split(/ \|\|\| /, $line);
  }
  $total++;

  if ($opts{b}) {
    if ($source =~ /^\s*$/ or $target =~ /^\s*$/) {
      $SKIPPED{blanks}++;
      next;
    }
  }

  if ($opts{u}) {
    my @symbols = split(' ', $source);

     # rule passes the filter if (a) it has more than one symbol or (b)
    # it has one symbol and that symbol is not a nonterminal
    if (@symbols == 1 and $symbols[0] =~ /^\[.*,1\]$/) {
      print STDERR "SKIPPING unary abstract rule $line" if $opts{v};
      $SKIPPED{unary}++;
      next;
    }
  }

  if ($opts{s}) {
    my $scope = get_scope($source);
    if ($opts{p}) {
      chomp($source);
      print "SCOPE($source) = $scope\n";
      next;
    }
    if ($scope > $opts{s}) {
      print STDERR "SKIPPING out-of-scope rule $line" if $opts{v};
      $SKIPPED{scope}++;

      if (is_lex($source)) {
        $SKIPPED{"lex"}++;
      } else {
        $SKIPPED{"unlex"}++;
      }
      next;
    }
  }

  if ($prev_source ne "" and $source ne $prev_source) {
    filter_and_print_rules(\@lines);
    @lines = ();
  }

  $prev_source = $source;
  push(@lines, $line);
}

filter_and_print_rules(\@lines);

my $skipped = sum(values(%SKIPPED));
print STDERR "filter-rules.pl: skipped $skipped of $total rules\n";
foreach my $key (keys %SKIPPED) {
  print STDERR "  skipped $key: $SKIPPED{$key}\n";
}

# If a config file was passed in, use the weights to weight all the rules for a source side, and print only the top $opts{t}
sub filter_and_print_rules {
  my ($rulelist) = @_;
  my @rules = @$rulelist;

  my @filtered_rules = ();
  if ($opts{t} and $opts{c}) {
    my %scores;
    foreach my $rule (@rules) {
      my @tokens = split(/ \|\|\| /, $rule);
      my $features = $tokens[3];
      my @features = split(" ", $features);
      my $score = 0.0;
      for (my $i = 0; $i < @features; $i++) {
        my $feature = $features[$i];
        if ($feature =~ /=/) {
          my ($key,$value) = split("=", $feature);
          $score += $WEIGHTS{$key} * $value;
        } else {
          $score += -1 * $WEIGHTS{"tm_$opts{o}_$i"} * $feature;
        }
      }
      $scores{$rule} = $score;
    }

    my @sorted_rules = sort {$scores{$b} <=> $scores{$a}} keys(%scores);
    @filtered_rules = splice(@sorted_rules, 0, $opts{t});
    $SKIPPED{redundant} += scalar(@sorted_rules) - scalar(@filtered_rules);

  } elsif ($opts{t}) {
    # Filter using field f (0-indexed), which is assumed to be the rarity penalty field
    my %counts;
    foreach my $rule (@rules) {
      my @tokens = split(/ \|\|\| /, $rule);
      if (@tokens < 6) {
        print STDERR "* WARNING, no counts present in field, not filtering\n";
        delete $opts{t};
        last;
      }
      my $countstr = $tokens[5];
      my @counts = split(" ", $countstr);
      my $count = $counts[0];
      $counts{$rule} = $count;
    }

    if (scalar(keys(%counts)) > 0) {
      my @sorted_rules = sort { $counts{$b} <=> $counts{$a} } keys(%counts);
      @filtered_rules = splice(@sorted_rules, 0, $opts{t});
      $SKIPPED{redundant} += scalar(@sorted_rules) - scalar(@filtered_rules);
    } else {
      @filtered_rules = @rules;
    }

  } else {
    @filtered_rules = @rules;
  }

  foreach my $rule (@filtered_rules) {
    print $rule;
  }
}

sub get_scope {
  my ($source) = @_;

  my @tokens = split(' ', $source);

  my $scope = 0;
  for (my $i = 0; $i < @tokens; $i++) {
    my $tok = $tokens[$i];
    if (is_nt($tok) && ($i == 0 || is_nt($tokens[$i-1]))) {
      $scope++;
    }
  }
  $scope++ if (is_nt($tokens[-1]));

  return $scope;
}

sub is_nt {
  my ($word) = @_;

  return 1 if $word =~ /^\[.*,\d+\]$/;
  return 0;
}

sub is_lex {
  my ($side) = @_;
  return grep { ! is_nt($_) } split(' ', $side);
}

sub read_weights {
  my ($config) = @_;

  my %weights;

  open READ, $config or die;
  while (my $line = <READ>) {
    chomp($line);
    next if ($line =~ /^\s*$/ or $line =~ /^#/ or $line =~ /=/);
    
    my ($key, $value) = split(" ", $line);
    $weights{$key} = $value;
  }
  close READ;

  return %weights;
}
