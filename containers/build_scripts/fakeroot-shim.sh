#!/bin/sh
# Sourced from a def's %post (copied in via %files):
#   . /opt/fakeroot-shim.sh on    -- before any apt-get
#   . /opt/fakeroot-shim.sh off   -- at the end of %post
#
# Bridges-2's unprivileged `apptainer build --fakeroot` mounts temporary
# /etc/passwd and /etc/group over the image's own. They can be written in
# place but not replaced, and groupadd/useradd replace them (write a temp
# file, then rename), so any package that adds a system user or group fails
# its setup (e.g. openssh-client's `groupadd _ssh`: "failure while writing
# changes to /etc/group").
#
# "on" diverts groupadd/useradd/groupmod/usermod to wrappers that run the
# real tool against a copy of /etc (--prefix) and write the results back in
# place. "off" restores the real tools. Without those mounts (e.g. ACES, or a
# root build) both are no-ops. systemd-sysusers isn't covered: don't install
# systemd (e.g. software-properties-common pulls it in).

_fr_tools="groupadd useradd groupmod usermod"

case "${1:-}" in
on)
    grep -qE ' /etc/(group|passwd) ' /proc/self/mountinfo || return 0
    for t in $_fr_tools; do
        dpkg-divert --quiet --local --rename --add "/usr/sbin/$t"
        cat > "/usr/sbin/$t" <<EOF
#!/bin/sh
d=\$(mktemp -d) || exit 1
mkdir -p "\$d/etc"
for f in passwd group shadow gshadow subuid subgid login.defs default; do
    [ -e "/etc/\$f" ] && cp -a "/etc/\$f" "\$d/etc/"
done
/usr/sbin/$t.distrib --prefix "\$d" "\$@"; rc=\$?
if [ \$rc -eq 0 ]; then
    for f in passwd group shadow gshadow; do
        [ -f "\$d/etc/\$f" ] && cat "\$d/etc/\$f" > "/etc/\$f"
    done
fi
rm -rf "\$d"
exit \$rc
EOF
        chmod 755 "/usr/sbin/$t"
    done
    ;;
off)
    for t in $_fr_tools; do
        if [ -e "/usr/sbin/$t.distrib" ]; then
            rm -f "/usr/sbin/$t"
            dpkg-divert --quiet --local --rename --remove "/usr/sbin/$t"
        fi
    done
    ;;
*)
    echo "usage: . fakeroot-shim.sh on|off" >&2
    return 1
    ;;
esac
