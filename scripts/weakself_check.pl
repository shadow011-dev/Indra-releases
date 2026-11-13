undef $/;
my $bad = 0;
for my $f (@ARGV) {
    open(my $h, '<', $f) or next;
    my $s = <$h>;
    while ($s =~ /(?:queue: \.main\)|repeats: true\)) \{ (?:_|note) in[ \t]*\n(?:[^\n]*\n){0,4}?[ \t]*(?:MainActor\.assumeIsolated \{ )?Task \{ \@MainActor \[weak self\]/g) { $bad++; print "$f\n"; }
}
exit($bad ? 1 : 0);
