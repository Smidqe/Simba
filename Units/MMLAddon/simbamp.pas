unit simbamp;

{
  This file is part of the Mufasa Macro Library (MML)
  Copyright (c) 2009-2012 by Raymond van Venetië and Merlijn Wajer

    MML is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    MML is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with MML.  If not, see <http://www.gnu.org/licenses/>.

  See the file COPYING, included in this distribution,
  for details about the copyright.

  Script Process Manager for Simba
}

{$mode objfpc}{$H+}

{
Notes:
  - Right now each client has to send its own id with every message.
    I didn't find a way to detect what client the message is from. I suppose
    this isn't all that weird considering it uses named pipes on Linux.

TODO:

    - Define a protocol which clients should follow.
    - Implement exception handling where required (pretty much everywhere)
    - Implement events (as procedure of object probably).
      Events:
        Simba:
          - OnWriteln (or something)
          - OnScriptStop

        Client:
          - OnStop

TODO MAYBE:
    - Change SimpleIPC(Client|Server).Create calls to use our own classes.
      Perhaps extend TComponent?

}

interface

uses
  Classes, SysUtils,

  { For TProcess }
  process,

  { For TSimpleIPC(Client,Server) }
  simpleipc;

const
  scWaitIdent = 0;
  scReady = 1;

type

  TWritelnProc = procedure(s: string);

  { Manager for Simba or some other daemon }
  TScriptProcessManager = class(TObject)
  private

    FScripts: TList;
    // TScriptCommunication list (one for each script)

  public
    FIPCServer: TSimpleIPCServer;   { TODO Make private }

    constructor Create;
    destructor Destroy;

    procedure Start;
    procedure Stop;
    procedure Add(O: TObject);
    procedure HandleEvents;

  public
    writeln_procedure: TWritelnProc;


  end;

  { Communication from Simba some daemon to the script }
  TScriptCommunication = class(TObject)
  private
    FIPCClient: TSimpleIPCClient; { IPC Client to the Scripts server }
    FParent: TScriptProcessManager; { The parent - we need this for the server }
    FProcess: TProcess; { The script process }
    FState: Integer; { State }
    FIdent: String;
  public
    constructor Create(Parent: TScriptProcessManager);
    destructor Destroy;
    procedure SetupConnection(ident: String);

    procedure StartScript;
    procedure StopScript;
    procedure SuspendScript;
    procedure ResumeScript;

    procedure WriteTo(s: String);
    procedure HandleMessage(s: String);
    procedure RecieveFrom(s: String);
    procedure HasMessage(s: String);
    // Several procedures to set up initial communication per script.
  end;

  { Communication from script process -> Simba }

  TScriptSideCommunication = class(TObject)
  private
    FServer: TSimpleIPCServer;
    FMaster: TSimpleIPCClient;

  public
    EventStop: procedure of object;

    constructor Create;
    destructor Destroy;


    procedure ConnectToMaster(InstanceID: String);
    procedure SetupServer;

    procedure DisconnectFromMaster;
    procedure StopServer;

    procedure HandleEvents;

    procedure WriteMessage(s: String);
  end;

implementation

constructor TScriptProcessManager.Create;

begin
  //inherited;

  FIPCServer := TSimpleIPCServer.Create(nil);
  FIPCServer.ServerID := 'Simba';
  FIPCServer.Global := False;

  FScripts := TList.Create;
end;

destructor TScriptProcessManager.Destroy;

begin
  { TODO kill all scripts? }
  FScripts.Free;

  inherited;
end;

procedure TScriptProcessManager.Add(O: TObject);
begin
  FScripts.Add(Pointer(O));
end;

procedure TScriptProcessManager.Start;
begin
  FIPCServer.StartServer;
end;

procedure TScriptProcessManager.Stop;
var
    script: TScriptCommunication;
begin
  while FScripts.Count <> 0 do
  begin
    script := TScriptCommunication(FScripts.Items[0]);
    script.StopScript;
    FScripts.Delete(0);
    script.Free;
  end;
  { TODO: Clean up here }

  FIPCServer.StopServer;
end;

function ParseMessage(s: String; var Client: String; var Message: String):
    Boolean;

var
    i, j, l: integer;
    f: boolean;
begin
  l := Length(s);
  i := 1;
  f := False;

  while i < l do
  begin
    if s[i] = ':' then
    begin
      f := True;
      break;
    end;
    i := i + 1;
  end;

  if not f then
    exit(False);

  setlength(client, i - 1);
  for j := 1 to i - 1 do
    client[j] := s[j];

  setlength(message, l - i);
  for j := i + 1 to l do
    message[j - i] := s[j];

  Result := True;
end;

{ TODO: Function? }
procedure TScriptProcessManager.HandleEvents;

var
    i: integer;
    s, c, m: String;
    script: TScriptCommunication;

begin
  if not FIPCServer.PeekMessage(0, False) then
    exit; {Return false?}

  while True do
  begin
    if not FIPCServer.PeekMessage(0, True) then
      exit;
    s := FIPCServer.StringMessage;
    c := ''; m := '';
    if not ParseMessage(s, c, m) then
    begin
      Writeln('Ignoring message: ' + s);
      Continue;
    end;

    writeln(format('Message from "%s": "%s"', [c, m]));

    script := nil;
    for i := 0 to FScripts.Count - 1 do
    begin
      writeln('Found ident: ' + TScriptCommunication(FScripts.Items[i]).FIdent);
      if TScriptCommunication(FScripts.Items[i]).FIdent = c then
      begin
        script := TScriptCommunication(FScripts.Items[i]);
        Writeln('Found script match');
        break;
      end;
    end;

    if Assigned(script) then
    begin
      writeln('Passing message ' + m + ' to script ' + s);
      script.HandleMessage(m);
    end else
    begin
      writeln('No script match');
    end;
  end;
end;

constructor TScriptCommunication.Create(Parent: TScriptProcessManager);
begin
  //inherited;

  FParent := Parent;
  FState := scWaitIdent;
  FIdent := '';

  Parent.Add(Self);
end;

destructor TScriptCommunication.Destroy;
begin
  { Foo }

  if assigned(FIPCClient) then
    FIPCClient.Free;

  inherited;
end;

{
  Call this once the parent server has recieved the ID of the clients server to
  which we will send messages.
}
procedure TScriptCommunication.SetupConnection(ident: String);
begin
  FIPCClient := TSimpleIPCClient.Create(nil);

  { Retrieve these from the client, we need the ID
    So this is only called once the client has send us its ID }
  FIPCClient.ServerID := 'SimbaClient'; { TODO GET VALUE }
  FIPCClient.ServerInstance := IntToStr(FProcess.ProcessId);

  FState := scReady;

  try
    FIPCClient.Connect;
    FIPCClient.Active := True;
    FIPCClient.SendStringMessage('ACK');
  except { TODO: Proper exception + message + error handling }
    Writeln('WHOOPS');
    { TODO: Kill client }
  end;
end;

{
  TODO:
      - Update this with new TProcess API
      - Pass arguments and binary location.
}
procedure TScriptCommunication.StartScript;
begin
  FProcess := TProcess.Create(nil); { TODO Owner }

  FProcess.CommandLine := '/tmp/client' + ' ' + FParent.FIPCServer.InstanceID;

  FProcess.Execute;

  FIdent := IntToStr(FProcess.ProcessID);
  writeln('Started process: ', FProcess.ProcessID);
end;

procedure TScriptCommunication.StopScript;
begin
  { Don't really need this right now }
  { We should probably tell the process it will be stopped first? }
  FIPCClient.SendStringMessage('stop');

  {
  sleep(100);
  FProcess.Terminate(0);   }

  { This is obviously not safe }
  FProcess.WaitOnExit;
  FProcess.Free;
end;

procedure TScriptCommunication.SuspendScript;
begin
  { Should we notify the process? How? }
  { We should probably tell the process it will be suspended first? }
  FProcess.Suspend;
end;

procedure TScriptCommunication.ResumeScript;
begin
  FProcess.Resume;
end;

procedure TScriptCommunication.WriteTo(s: String);
begin
  FIPCClient.SendStringMessage(s);
end;

procedure TScriptCommunication.HandleMessage(s: String);
begin
  case FState of
    scWaitIdent:
        begin
          SetupConnection(s);
        end;
    scReady:
        begin
          writeln('Message: ' + s);

          if s = 'quit' then
              StopScript

          else
            if Assigned(FParent.writeln_procedure) then
              FParent.writeln_procedure(s)
            else
              writeln('Client ' + FIdent + ' writes: ' + s);
        end;
  end;
end;

procedure TScriptCommunication.RecieveFrom(s: String);
begin
  { Leave this empty }
end;

procedure TScriptCommunication.HasMessage(s: String);
begin
  { Leave this empty }
end;


{ TScriptSideCommunication }
constructor TScriptSideCommunication.Create;
begin
  //inherited;

  FServer := TSimpleIPCServer.Create(nil);

  FMaster := TSimpleIPCClient.Create(nil);

  EventStop := nil;
end;

destructor TScriptSideCommunication.Destroy;
begin


  //inherited;
end;

procedure TScriptSideCommunication.ConnectToMaster(InstanceID: String);
begin
  FMaster.ServerID := 'Simba';
  FMaster.ServerInstance := InstanceID;

  FMaster.Connect;
  FMaster.Active := True;
end;

procedure TScriptSideCommunication.DisconnectFromMaster;
begin
  FMaster.Active := False;
  FMaster.Disconnect;
  FMaster.Free;
end;

procedure TScriptSideCommunication.SetupServer;
begin
  FServer.Global := False;

  FServer.ServerID := 'SimbaClient';
  FServer.StartServer;

  { Tell the Master about our server }
  FMaster.SendStringMessage(FServer.InstanceID + ': Done');
end;

procedure TScriptSideCommunication.StopServer;
begin
  FServer.StopServer;
  FServer.Free;
end;

procedure TScriptSideCommunication.HandleEvents;

var
    i: integer;
    s: String;

begin
  if not FServer.PeekMessage(0, False) then
    exit;

  while True do
  begin
    if not FServer.PeekMessage(0, True) then
        break;
    s := FServer.StringMessage;
    begin
      if s = 'stop' then
      begin
        writeln('We should stop!');
        if Assigned(EventStop) then
        begin
          writeln('Calling EventStop');
          EventStop();
        end
        else
        begin
          writeln('Throwing exception');
          Exception.Create('Recieved stop and no stop handler');
        end;

        { XXX TODO: Do something useful. Perhaps events? }
      end;
    end;
  end;
end;

procedure TScriptSideCommunication.WriteMessage(s: String);
begin
  FMaster.SendStringMessage(FServer.InstanceID + ': ' + s);
end;

end.
