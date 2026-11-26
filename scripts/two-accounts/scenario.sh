#!/bin/bash
# docs/security.md "Running tests in a separate account", checked: what the test account cannot
# touch, and that runs it records are followed, finalized, signed, cancelled and deleted.
set -u
ok() { echo "ok    $1"; }; bad() { echo "FAIL  $1"; FAILED=1; }; FAILED=0
api() { pwsh -NoProfile -Command "\$c = [pscredential]::new('ada', (ConvertTo-SecureString 'correct horse battery staple' -AsPlainText -Force)); $1"; }
as_runner() { runuser -u runner -- "$@"; }

# What an installer does on a real host (image layers drop ACLs): the test account may write
# run data, and whatever it creates there stays the service's to change and delete.
for d in runs logs screenshots artifacts cancel; do
  setfacl -m u:runner:rwx,u:testor:rwx /srv/testor/home/$d
  setfacl -d -m u:runner:rwx,u:testor:rwx /srv/testor/home/$d
done
runuser -u testor -- /app/bin/testor daemon
for i in $(seq 1 30); do runuser -u testor -- /app/bin/testor eval 'Testor.Probe.check()' 2>/dev/null && break; sleep 1; done
runuser -u testor -- env TESTOR_PASSWORD='correct horse battery staple' /app/bin/testor eval 'Testor.Auth.CLI.user ~s[ada], ~s[admin]' >/dev/null 2>&1
sleep 2

# The test account cannot reach testor's secrets, its wrapper or its home.
as_runner cat /srv/testor/secrets/jwt.key >/dev/null 2>&1 && bad "runner reads jwt.key" || ok "the test account cannot read the secrets"
as_runner sh -c 'echo x >> /srv/testor/home/run.ps1' 2>/dev/null && bad "runner changes run.ps1" || ok "the test account cannot change run.ps1"
as_runner mv /srv/testor/home /srv/testor/stolen 2>/dev/null && bad "runner moves the home" || ok "the test account cannot replace the testor home"
as_runner sh -c 'echo "{}" > /srv/testor/home/auth.json' 2>/dev/null && bad "runner plants auth.json" || ok "the test account cannot plant auth.json"

# A run recorded by the test account is followed, finalized and signed by the service.
as_runner pwsh -NoProfile -Command 'Set-Location /srv/workspaces; $env:TESTOR_ACTOR = "ada@laptop"; & /srv/testor/home/run.ps1 -Project two -Kind test -Body { " ✓ tests/a.test.ts (2 tests) 5ms" }' >/dev/null
sleep 3
id=$(ls /srv/testor/home/runs | head -1 | sed 's/.json$//')
for i in $(seq 1 20); do [ -f /srv/testor/home/attestations/$id.dsse.json ] && break; sleep 0.5; done
api "\$r = Invoke-RestMethod -AllowUnencryptedAuthentication -Credential \$c -Authentication Basic http://127.0.0.1:6767/api/v1/runs/$id; '{0} {1} {2} {3}' -f \$r.run.status, \$r.run.summary.specs, \$r.run.attested, \$r.run.actor.user" > /tmp/r.txt
read status specs attested user < /tmp/r.txt
[ "$status" = passed ] && [ "$specs" = 1 ] && ok "the service finalized the run (passed, 1 spec)" || bad "finalize: $(cat /tmp/r.txt)"
[ "$attested" = True ] && ok "the service signed it" || bad "attested=$attested"
[ "$user" = runner ] && ok "the run names the test account (actor.user=runner)" || bad "actor=$user"

# Cancel: the service cannot kill the test account's processes; the run ends itself when asked.
as_runner pwsh -NoProfile -Command 'Set-Location /srv/workspaces; & /srv/testor/home/run.ps1 -Project two -Kind slow -Body { sleep 120 }' >/dev/null 2>&1 &
sleep 4
slow=$(grep -l '"status": *"running"' /srv/testor/home/runs/*.json | head -1 | xargs basename | sed 's/.json$//')
start=$(date +%s%3N)
api "\$r = Invoke-RestMethod -AllowUnencryptedAuthentication -Credential \$c -Authentication Basic -Method Post -ContentType application/json -Body '{}' http://127.0.0.1:6767/api/v1/runs/$slow/cancel; '{0}|{1}' -f \$r.status, \$r.warning" > /tmp/c.txt
took=$(( ($(date +%s%3N) - start) ))ms
IFS='|' read cstatus cwarn < /tmp/c.txt
[ "$cstatus" = cancelled ] && [ -z "$cwarn" ] && ok "cancel ends the test account's run, no warning (${took})" || bad "cancel: $(cat /tmp/c.txt)"
sleep 1; pgrep -u runner -f "sleep 120" >/dev/null && bad "the sleep survived" || ok "the run's whole tree is gone"

# Deleting: the service removes files and folders the test account wrote.
mkdir_out=$(as_runner pwsh -NoProfile -Command 'Set-Location /srv/workspaces; New-Item -ItemType Directory -Force test-results | Out-Null; & /srv/testor/home/run.ps1 -Project two -Kind shots -Body { [IO.File]::WriteAllBytes((Join-Path $PWD "test-results/a.png"), [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)) }' 2>&1)
sleep 3
shots=$(grep -l '"kind": *"shots"' /srv/testor/home/runs/*.json | head -1 | xargs basename | sed 's/.json$//')
[ -d /srv/testor/home/screenshots/$shots ] && ok "the run kept a screenshot folder (written by the test account)" || bad "no screenshot folder: $mkdir_out"
api "\$null = Invoke-RestMethod -AllowUnencryptedAuthentication -Credential \$c -Authentication Basic -Method Delete -Headers @{'X-Testor'='1'} http://127.0.0.1:6767/api/v1/runs/$shots" 
[ ! -e /srv/testor/home/screenshots/$shots ] && [ ! -e /srv/testor/home/runs/$shots.json ] && ok "the service deleted the run and its screenshot folder" || bad "delete left files: $(ls -la /srv/testor/home/screenshots/$shots 2>&1 | head -3)"

exit $FAILED
