function psFormat(const fmt : string;const args : array of const) : string;
begin;
  Result := Format(fmt,Args);
end;

function Capitalize(str : string) : string;
var
  i , l : integer;
  cap : boolean;
begin;
  result := str;
  l := length(str);
  cap := true;
  for i := 1 to l do
    if cap and (str[i] in ['a'..'z'] + ['A'..'Z']) then
    begin;
      result[i] := UpperCase(str[i])[1];
      cap := false;
    end else if not (str[i] in ['a'..'z'] + ['A'..'Z']) then
      cap := true;
end;

function psBoolToStr(bool : boolean) : string;
begin;
  result := BoolToStr(bool,true);
end;