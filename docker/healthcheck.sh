#!/bin/bash
# Healthy when all NeDi services are running and the GUI answers
set -eu

status="$(supervisorctl -c /etc/supervisor/nedi.conf status || true)"
if grep -v RUNNING <<<"$status"; then
    exit 1
fi

perl -MLWP::UserAgent -e '
    my $res = LWP::UserAgent->new(timeout => 5)->get("http://127.0.0.1/index.php");
    $res->is_success or die "GUI: " . $res->status_line . "\n";
'
