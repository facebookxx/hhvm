(*
 * Copyright (c) 2019, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel

module Status = struct
  type t =
    | Not_started
    | Initializing
    | Processing_files of ClientIdeMessage.Processing_files.t
    | Ready
    | Stopped of string
end

module Stop_reason = struct
  type t =
    | Crashed
    | Editor_exited
    | Restarting
    | Testing

  let to_string (t : t) =
    match t with
    | Crashed -> "crashed"
    | Editor_exited -> "editor exited"
    | Restarting -> "restarting"
    | Testing -> "testing-only, you should not see this"
end

type state =
  | Uninitialized of { wait_for_initialization: bool }
  | Failed_to_initialize of string
  | Initialized of { status: Status.t }
  | Stopped of Stop_reason.t

type message_wrapper =
  | Message_wrapper : 'a ClientIdeMessage.tracked_t -> message_wrapper
      (** Existential type wrapper for `ClientIdeMessage.t`s, so that we can put
      them in a queue without the typechecker trying to infer a concrete type for
      `'a` based on its first use. *)

type message_queue = message_wrapper Lwt_message_queue.t

type response_wrapper =
  | Response_wrapper : ('a, string) result -> response_wrapper
      (** Similar to [Message_wrapper] above. *)

type response_emitter = response_wrapper Lwt_message_queue.t

type notification_emitter = ClientIdeMessage.notification Lwt_message_queue.t

type t = {
  mutable state: state;
  state_changed_cv: unit Lwt_condition.t;
      (** Used to notify tasks when the state changes, so that they can wait for the
    IDE service to be initialized. *)
  daemon_handle: (unit, unit) Daemon.handle;
      (** The handle to the daemon process backing the IDE service.

      Note that `(unit, unit)` here refers to the input and output types of the
      IDE service. However, we don't use the Daemon API's method of
      producing/consuming these messages and instead do it with Lwt, so these
      type parameters are not used. *)
  in_fd: Lwt_unix.file_descr;
  out_fd: Lwt_unix.file_descr;
  messages_to_send: message_queue;
      (** The queue of messages that we have yet to send to the daemon. *)
  response_emitter: response_emitter;
      (** The queue of responses that we received from RPC calls to the daemon. We
      assume that we receive the responses in the same order that we sent their
      requests. *)
  notification_emitter: notification_emitter;
      (** The queue of notifications that the daemon emitted. Notifications can be
      emitted at any time, not just in response to an RPC call. *)
}

let set_state (t : t) (new_state : state) : unit =
  t.state <- new_state;
  Lwt_condition.broadcast t.state_changed_cv ()

let log s = Hh_logger.log ("[ide-service] " ^^ s)

let do_rpc
    ~(tracked_message : 'a ClientIdeMessage.tracked_t)
    ~(messages_to_send : message_queue)
    ~(response_emitter : response_emitter) : ('a, string) Lwt_result.t =
  try%lwt
    let success =
      Lwt_message_queue.push messages_to_send (Message_wrapper tracked_message)
    in
    if not success then failwith "Could not send message (queue was closed)";

    let%lwt (response : response_wrapper option) =
      Lwt_message_queue.pop response_emitter
    in
    match response with
    | None -> failwith "Could not read response: queue was closed"
    | Some (Response_wrapper response) ->
      (* We don't carry around the tag at runtime that tells us what type of
      message the response was for. We're relying here on the invariant that
      responses are provided in the order that requests are sent, and that we're
      not sending any requests in parallel. This looks unsafe, but it's not
      adding additional un-safety. The `Response` message here came from
      `Marshal_tools_lwt.from_fd_with_preamble`, which is inherently unsafe
      (returns `'a`), and we've just happened to pass around that `'a` rather
      than coercing its type immediately. *)
      let response = Result.map ~f:Obj.magic response in
      Lwt.return response
  with e ->
    let stack = Printexc.get_backtrace () in
    let exn_message = Exn.to_string e in
    let message =
      Printf.sprintf
        "Exception occurred while handling RPC call: %s\nStack: %s"
        exn_message
        stack
    in
    Lwt.return_error message

let make ~(init_id : string) : t =
  let args = init_id in
  let daemon_handle =
    Daemon.spawn
      ~channel_mode:`pipe
      (Unix.stdin, Unix.stdout, Unix.stderr)
      ClientIdeDaemon.daemon_entry_point
      args
  in
  let (ic, oc) = daemon_handle.Daemon.channels in
  let in_fd = Lwt_unix.of_unix_file_descr (Daemon.descr_of_in_channel ic) in
  let out_fd = Lwt_unix.of_unix_file_descr (Daemon.descr_of_out_channel oc) in
  {
    state = Uninitialized { wait_for_initialization = false };
    state_changed_cv = Lwt_condition.create ();
    daemon_handle;
    in_fd;
    out_fd;
    messages_to_send = Lwt_message_queue.create ();
    response_emitter = Lwt_message_queue.create ();
    notification_emitter = Lwt_message_queue.create ();
  }

let rec wait_for_initialization (t : t) : unit Lwt.t =
  match t.state with
  | Uninitialized _
  | Failed_to_initialize _ ->
    let%lwt () = Lwt_condition.wait t.state_changed_cv in
    wait_for_initialization t
  | Initialized _ -> Lwt.return_unit
  | Stopped _ ->
    failwith
      ( "Should not be waiting for the initialization of a stopped IDE service, "
      ^ "as this is a terminal state" )

let initialize_from_saved_state
    (t : t)
    ~(root : Path.t)
    ~(naming_table_saved_state_path : Path.t option)
    ~(wait_for_initialization : bool)
    ~(use_ranked_autocomplete : bool) : (unit, string) Lwt_result.t =
  set_state t (Uninitialized { wait_for_initialization });

  let param =
    {
      ClientIdeMessage.Initialize_from_saved_state.root;
      naming_table_saved_state_path;
      use_ranked_autocomplete;
    }
  in
  (* Do not use `do_rpc` here, as that depends on a running event loop in
  `serve`. But `serve` should only be called once the IDE service is
  initialized, after this function has completed. *)
  let message = ClientIdeMessage.Initialize_from_saved_state param in
  let tracked_message = { ClientIdeMessage.tracking_id = "init"; message } in
  let%lwt (_ : int) =
    Marshal_tools_lwt.to_fd_with_preamble t.out_fd tracked_message
  in
  let%lwt (response : ClientIdeMessage.message_from_daemon) =
    Marshal_tools_lwt.from_fd_with_preamble t.in_fd
  in
  match response with
  | ClientIdeMessage.Response (Ok _)
  (* expected to be `Ok ()`, but not statically-checkable *) ->
    log
      "Initialized IDE service process (log file at %s)"
      (ServerFiles.client_ide_log root);
    set_state t (Initialized { status = Status.Ready });
    Lwt.return_ok ()
  | ClientIdeMessage.Notification _ ->
    let error_message =
      "Failed to initialize IDE service process "
      ^ "because we received a notification before the initialization response"
    in
    log "%s" error_message;
    set_state t (Failed_to_initialize error_message);
    Lwt.return_error error_message
  | ClientIdeMessage.Response (Error error_message) ->
    log "Failed to initialize IDE service process: %s" error_message;
    set_state t (Failed_to_initialize "could not load saved-state");
    Lwt.return_error error_message

let process_status_notification
    (t : t) (notification : ClientIdeMessage.notification) : unit =
  match t.state with
  | Uninitialized _
  | Failed_to_initialize _
  | Stopped _ ->
    ()
  | Initialized _state ->
    (match notification with
    | ClientIdeMessage.Initializing ->
      set_state t (Initialized { status = Status.Initializing })
    | ClientIdeMessage.Processing_files processed_files ->
      set_state
        t
        (Initialized { status = Status.Processing_files processed_files })
    | ClientIdeMessage.Done_processing ->
      set_state t (Initialized { status = Status.Ready }))

let destroy (t : t) ~(tracking_id : string) : unit Lwt.t =
  let {
    daemon_handle;
    messages_to_send;
    response_emitter;
    notification_emitter;
    _;
  } =
    t
  in
  let%lwt () =
    match t.state with
    | Uninitialized _
    | Failed_to_initialize _
    | Stopped _ ->
      Lwt.return_unit
    | Initialized _ ->
      let t = Unix.gettimeofday () in
      (try%lwt
         let message = ClientIdeMessage.Shutdown () in
         let tracked_message = { ClientIdeMessage.tracking_id; message } in
         let%lwt () =
           Lwt.pick
             [
               (let%lwt (_result : (unit, string) result) =
                  do_rpc ~tracked_message ~messages_to_send ~response_emitter
                in
                Daemon.kill daemon_handle;
                HackEventLogger.serverless_ide_destroy_ok t;
                Lwt.return_unit);
               (let%lwt () = Lwt_unix.sleep 5.0 in
                Daemon.kill daemon_handle;
                let stack = Exception.get_current_callstack_string 100 in
                HackEventLogger.serverless_ide_destroy_error
                  t
                  ("Timeout\n" ^ stack);
                log "ClientIdeService.destroy timeout";
                Lwt.return_unit);
             ]
         in
         Lwt.return_unit
       with e ->
         let e = Exception.wrap e in
         HackEventLogger.serverless_ide_destroy_error t (Exception.to_string e);
         log "ClientIdeService.destroy error\n%s" (Exception.to_string e);
         Lwt.return_unit)
  in
  Lwt_message_queue.close messages_to_send;
  Lwt_message_queue.close notification_emitter;
  Lwt_message_queue.close response_emitter;
  Lwt.return_unit

let stop (t : t) ~(tracking_id : string) ~(reason : Stop_reason.t) : unit Lwt.t
    =
  let%lwt () = destroy t ~tracking_id in
  (* Correctness here is very subtle... During the course of that call to
  'destroy', we do let%lwt on an rpc call to shutdown the daemon.
  Either that will return in 5s, or it won't; either way, we will
  synchronously kill the daemon handle and close the message queus.
  The interleaving we have to worry about is: what will other code
  do while the state is still "Initialized", after we've sent the shutdown
  message to the daemon, and we're let%lwt awaiting for a responnse?
  Will anything go wrong?
  Well, the daemon has responded to 'shutdown' by deleting its hhi dir
  but leaving itself in its "Initialized" state.
  Meantime, some of our code uses the state "Stopped" as a signal to not
  do work, and some uses a closed message-queue as a signal to not do work
  and neither is met. We might indeed receive further requests from
  clientLsp and dutifully pass them on to the daemon and have it fail
  weirdly because of the lack of hhi.
  Luckily we're saved from that because clientLsp never makes rpc requests
  to us after it has called 'stop'. *)
  set_state t (Stopped reason);
  Lwt.return_unit

let rec serve (t : t) : unit Lwt.t =
  let send_queued_up_messages ~out_fd messages_to_send : bool Lwt.t =
    let%lwt next_message = Lwt_message_queue.pop messages_to_send in
    match next_message with
    | None -> Lwt.return false
    | Some (Message_wrapper next_message) ->
      let%lwt (_ : int) =
        Marshal_tools_lwt.to_fd_with_preamble out_fd next_message
      in
      Lwt.return true
  in
  let emit_messages_from_daemon ~in_fd response_emitter notification_emitter :
      bool Lwt.t =
    let%lwt (message : ClientIdeMessage.message_from_daemon) =
      Marshal_tools_lwt.from_fd_with_preamble in_fd
    in
    match message with
    | ClientIdeMessage.Notification notification ->
      process_status_notification t notification;
      Lwt.return (Lwt_message_queue.push notification_emitter notification)
    | ClientIdeMessage.Response response ->
      Lwt.return
        (Lwt_message_queue.push response_emitter (Response_wrapper response))
  in
  let%lwt should_continue =
    try%lwt
      (* We mutate the data in `t`, which is why we don't return a new `t` here.
      *)
      let%lwt should_continue =
        Lwt.pick
          [
            send_queued_up_messages ~out_fd:t.out_fd t.messages_to_send;
            emit_messages_from_daemon
              ~in_fd:t.in_fd
              t.response_emitter
              t.notification_emitter;
          ]
      in
      if should_continue = false then
        HackEventLogger.serverless_ide_crash
          ~message:
            "No crash, but should_continue set to false by message queue."
          ~stack:"No stack";
      Lwt.return should_continue
    with e ->
      let e = Exception.wrap e in
      let stack = Exception.get_backtrace_string e in
      let message = Exception.to_string e in
      HackEventLogger.serverless_ide_crash ~message ~stack;
      log "Exception occurred in ClientIdeService.serve: %s" message;
      Lwt.return false
  in
  if should_continue then
    serve t
  else (
    log "Shutting down";
    match t.state with
    | Stopped _ ->
      (* Already stopped, don't do anything. *)
      Lwt.return_unit
    | _ ->
      let%lwt () =
        stop t ~tracking_id:"exception" ~reason:Stop_reason.Crashed
      in
      Lwt.return_unit
  )

let push_message (t : t) (message : message_wrapper) : unit =
  match t.state with
  | Uninitialized _
  | Initialized _ ->
    let _success : bool = Lwt_message_queue.push t.messages_to_send message in
    ()
  | Failed_to_initialize _
  | Stopped _ ->
    (* This is a terminal state. Don't waste memory queueing up messages that
    can never be sent. *)
    ()

let notify_file_changed (t : t) ~(tracking_id : string) (path : Path.t) : unit =
  let message = ClientIdeMessage.File_changed path in
  push_message t (Message_wrapper { ClientIdeMessage.tracking_id; message })

(* Simplified function for handling initialization cases *)
let rpc (t : t) ~(tracking_id : string) (message : 'a ClientIdeMessage.t) :
    ('a, string) Lwt_result.t =
  let { messages_to_send; response_emitter; _ } = t in
  let tracked_message = { ClientIdeMessage.tracking_id; message } in
  match t.state with
  | Uninitialized { wait_for_initialization = false } ->
    Lwt.return_error "IDE service has not yet been initialized"
  | Failed_to_initialize error_message ->
    Lwt.return_error
      (Printf.sprintf "IDE service failed to initialize: %s" error_message)
  | Stopped reason ->
    Lwt.return_error
      (Printf.sprintf
         "IDE service is stopped: %s"
         (Stop_reason.to_string reason))
  | Uninitialized { wait_for_initialization = true } ->
    let%lwt () = wait_for_initialization t in
    let%lwt result =
      do_rpc ~tracked_message ~messages_to_send ~response_emitter
    in
    Lwt.return result
  | Initialized _ ->
    let%lwt result =
      do_rpc ~tracked_message ~messages_to_send ~response_emitter
    in
    Lwt.return result

let get_notifications (t : t) : notification_emitter = t.notification_emitter

let get_status (t : t) : Status.t =
  match t.state with
  | Uninitialized _ -> Status.Initializing
  | Failed_to_initialize message -> Status.Stopped message
  | Stopped reason -> Status.Stopped (Stop_reason.to_string reason)
  | Initialized { status } -> status
