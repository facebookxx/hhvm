<?hh
<<__EntryPoint>> function main(): void {
try { var_dump(strncasecmp("")); } catch (Exception $e) { echo "\n".'Warning: '.$e->getMessage().' in '.__FILE__.' on line '.__LINE__."\n"; }
var_dump(strncasecmp("", "", -1));
var_dump(strncasecmp("aef", "dfsgbdf", 0));
var_dump(strncasecmp("aef", "dfsgbdf", 10));
var_dump(strncasecmp("qwe", "qwer", 3));
var_dump(strncasecmp("qwerty", "QweRty", 6));
var_dump(strncasecmp("qwErtY", "qwer", 7));
var_dump(strncasecmp("q123", "Q123", 3));
var_dump(strncasecmp("01", "01", 1000));

echo "Done\n";
}
