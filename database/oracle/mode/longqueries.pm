#
# Copyright 2017 Centreon (http://www.centreon.com/)
#
# Centreon is a full-fledged industry-strength solution that meets
# the needs in IT infrastructure and application monitoring for
# service performance.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package database::oracle::mode::longqueries;

use base qw(centreon::plugins::templates::counter);

use strict;
use warnings;
use centreon::plugins::misc;
use centreon::plugins::statefile;

my $instance_mode;

sub custom_status_threshold {
    my ($self, %options) = @_; 
    my $status = 'ok';
    my $message;
    
    eval {
        local $SIG{__WARN__} = sub { $message = $_[0]; };
        local $SIG{__DIE__} = sub { $message = $_[0]; };
        
        if (defined($instance_mode->{option_results}->{critical_status}) && $instance_mode->{option_results}->{critical_status} ne '' &&
            eval "$instance_mode->{option_results}->{critical_status}") {
            $status = 'critical';
        } elsif (defined($instance_mode->{option_results}->{warning_status}) && $instance_mode->{option_results}->{warning_status} ne '' &&
                 eval "$instance_mode->{option_results}->{warning_status}") {
            $status = 'warning';
        }
    };
    if (defined($message)) {
        $self->{output}->output_add(long_msg => 'filter status issue: ' . $message);
    }

    return $status;
}

sub custom_status_output {
    my ($self, %options) = @_;
    
    my $msg = sprintf("query [status: %s] [sql: %s] %s", $self->{result_values}->{status},
        $self->{result_values}->{sql_text}, $self->{result_values}->{generation_time});
    return $msg;
}

sub custom_status_calc {
    my ($self, %options) = @_;
    
    $self->{result_values}->{status} = $options{new_datas}->{$self->{instance} . '_status'};
    $self->{result_values}->{sql_text} = $options{new_datas}->{$self->{instance} . '_sql_text'};
    $self->{result_values}->{username} = $options{new_datas}->{$self->{instance} . '_username'};
    $self->{result_values}->{since} = $options{new_datas}->{$self->{instance} . '_since'};
    $self->{result_values}->{generation_time} = $options{new_datas}->{$self->{instance} . '_generation_time'};
    return 0;
}


sub set_counters {
    my ($self, %options) = @_;
    
    $self->{maps_counters_type} = [
        { name => 'alarms', type => 2, message_multiple => '0 problem(s) detected', display_counter_problem => { label => 'alerts', min => 0 },
          group => [ { name => 'alarm', skipped_code => { -11 => 1 } } ] 
        }
    ];
    
    $self->{maps_counters}->{alarm} = [
        { label => 'status', threshold => 0, set => {
                key_values => [ { name => 'status' }, { name => 'sql_text' }, { name => 'since' }, { name => 'username' }, { name => 'generation_time' } ],
                closure_custom_calc => $self->can('custom_status_calc'),
                closure_custom_output => $self->can('custom_status_output'),
                closure_custom_perfdata => sub { return 0; },
                closure_custom_threshold_check => $self->can('custom_status_threshold'),
            }
        },
    ];
}

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;
    
    $self->{version} = '1.0';
    $options{options}->add_options(arguments =>
                                {
                                  "warning-status:s"    => { name => 'warning_status', default => '' },
                                  "critical-status:s"   => { name => 'critical_status', default => '' },
                                  "memory"              => { name => 'memory' },
                                  "timezone:s"          => { name => 'timezone' },
                                });
    
    centreon::plugins::misc::mymodule_load(output => $self->{output}, module => 'DateTime',
                                           error_msg => "Cannot load module 'DateTime'.");
    $self->{statefile_cache} = centreon::plugins::statefile->new(%options);
    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::check_options(%options);

    $instance_mode = $self;
    $self->change_macros();
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->check_options(%options);
    }
    
    if (defined($self->{option_results}->{timezone}) && $self->{option_results}->{timezone} ne '') {
        $ENV{TZ} = $self->{option_results}->{timezone};
    }
}

sub change_macros {
    my ($self, %options) = @_;
    
    foreach (('warning_status', 'critical_status')) {
        if (defined($self->{option_results}->{$_})) {
            $self->{option_results}->{$_} =~ s/%\{(.*?)\}/\$self->{result_values}->{$1}/g;
        }
    }
}

sub manage_selection {
    my ($self, %options) = @_;
    $self->{sql} = $options{sql};
    $self->{sql}->connect();

    if (!$self->{sql}->is_version_minimum(version => '11')) {
        $self->{output}->add_option_msg(short_msg => "Need oracle version >= 11");
        $self->{output}->option_exit();
    }
    
    $self->{alarms}->{global} = { alarm => {} };
    
    my $query = q{
        SELECT status, (sql_exec_start - date '1970-01-01')*24*60*60) as sql_exec_start, elapsed_time
                FROM v$sql_monitor
    };
    if ($self->{sql}->is_version_minimum(version => '12')) {
        $query = q{
            SELECT status, (sql_exec_start - date '1970-01-01')*24*60*60) as sql_exec_start, elapsed_time, username, sql_text
                FROM v$sql_monitor
        };
    }
    $self->{sql}->query(query => $query);
    
    my $last_time;
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->read(statefile => "cache_oracle_" . $self->{mode} . $self->{sql}->get_unique_id4save());
        $last_time = $self->{statefile_cache}->get(name => 'last_time');
    }

    my ($i, $current_time) = (1, time());
    while ((my $row = $self->{sql}->fetchrow_hashref())) {
        my @values = localtime($row->{sql_exec_start});
        my $dt = DateTime->new(
            year       => $values[5] + 1900,
            month      => $values[4] + 1,
            day        => $values[3],
            hour       => $values[2],
            minute     => $values[1],
            second     => $values[0],
            time_zone  => 'UTC',
        );

        next if (defined($self->{option_results}->{memory}) && defined($last_time) && $last_time > $dt->epoch);
        $row->{sql_text} =~ s/(\n|\|)/-/ms if (defined($row->{sql_text}));

        my $since = $row->{elapsed_time} / 1000000;
        $self->{alarms}->{global}->{alarm}->{$i} = { 
            sql_text => $row->{sql_text},
            status => $row->{status},
            sql_text => defined($row->{sql_text}) ? $row->{sql_text} : '-',
            username => defined($row->{username}) ? $row->{username} : '-',
            since => $since, 
            generation_time => centreon::plugins::misc::change_seconds(value => $since) };
        $i++;
    }
    
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->write(data => { last_time => $current_time });
    }
}
        
1;

__END__

=head1 MODE

Check long sql queries.

=over 8

=item B<--warning-status>

Set warning threshold for status (Default: '')
Can used special variables like: %{username}, %{sql_text}, %{since}, %{status}

=item B<--critical-status>

Set critical threshold for status (Default: '').
Can used special variables like: %{username}, %{sql_text}, %{since}, %{status}

=item B<--timezone>

Timezone of oracle server (If not set, we use current server execution timezone).

=item B<--memory>

Only check new queries.

=back

=cut