<?hh
<<__EntryPoint>>
function main_entry(): void {

  print "Test begin\n";

  require_once 'reqonce2.inc';
  print "Between require_once invocations\n";
  require_once 'reqonce2.inc';

  print "Test end\n";
}
