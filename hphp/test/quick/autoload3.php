<?hh

HH\autoload_set_paths(
  dict[
    'class' => dict[
      'b' => 'autoload3-1.inc',
      'i' => 'autoload3-2.inc',
      'j' => 'autoload3-3.inc',
      'k' => 'autoload3-4.inc',
      'l' => 'autoload3-5.inc',
    ],
  ],
  __DIR__.'/',
);

class C extends B implements I, j {
}

interface P extends K, l {
}

$obj = new C;
echo "Done\n";
