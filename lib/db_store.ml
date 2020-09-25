open Lwt.Infix

let ( / ) = Filename.concat
let ( >>!= ) = Lwt_result.bind

module Make (Raw : S.STORE) = struct
  type build = {
    mutable users : int;
    cancelled : unit Lwt.t;
    set_cancelled : unit Lwt.u;         (* Resolve this to cancel (when [users = 0]). *)
    log : Build_log.t Lwt.t;
    result : (S.id, [`Cancelled | `Msg of string]) Lwt_result.t;
  }

  module Builds = Map.Make(String)

  type t = {
    raw : Raw.t;
    dao : Dao.t;
    (* Invariant: builds in [in_progress] have [users > 0], a [log] that isn't
       finished (i.e. can be tailed), a [cancelled] that is still pending, and a
       [result] that is still pending. *)
    mutable in_progress : build Builds.t;
  }

  let finish_log ~set_log log =
    match Lwt.state log with
    | Lwt.Return log ->
      Build_log.finish log
    | Lwt.Fail _ ->
      Lwt.return_unit
    | Lwt.Sleep ->
      Lwt.wakeup_exn set_log (Failure "Build ended without setting a log!");
      Lwt.return_unit

  let dec_ref t ~id build =
    build.users <- build.users - 1;
    Log.info (fun f ->
        if Lwt.is_sleeping build.result then
          f "User cancelled job (users now = %d)" build.users
      );
    if build.users = 0 then (
      (* Remove it immediately, so that no other user can try to attach to it. *)
      t.in_progress <- Builds.remove id t.in_progress;
      Lwt.wakeup_later build.set_cancelled ()
    )

  (* Check to see if we're in the process of building [id].
     If so, just tail the log from that.
     If not, call [fn set_log] to start a new build.
     [fn] should set the log being used as soon as it knows it
     (this can't happen until we've created the temporary directory
     in the underlying store). *)
  let share_build ?switch t ~log:client_log id fn =
    match Builds.find_opt id t.in_progress with
    | Some existing ->
      existing.users <- existing.users + 1;
      existing.log >>= fun log ->
      Lwt_switch.add_hook_or_exec switch (fun () -> dec_ref t ~id existing; Lwt.return_unit) >>= fun () ->
      Build_log.tail ?switch log (client_log `Output) >>!= fun () ->
      existing.result
    | None ->
      let result, set_result = Lwt.wait () in
      let log, set_log = Lwt.wait () in
      let tail_log = log >>= fun log -> Build_log.tail ?switch log (client_log `Output) in
      let cancelled, set_cancelled = Lwt.wait () in
      let build = { users = 1; cancelled; set_cancelled; log; result } in
      Lwt_switch.add_hook_or_exec switch (fun () -> dec_ref t ~id build; Lwt.return_unit) >>= fun () ->
      t.in_progress <- Builds.add id build t.in_progress;
      Lwt.async
        (fun () ->
           Lwt.try_bind
             (fun () -> fn ~cancelled set_log)
             (fun r ->
                if build.users > 0 then
                  t.in_progress <- Builds.remove id t.in_progress;
                Lwt.wakeup_later set_result r;
                finish_log ~set_log log
             )
             (fun ex ->
                if build.users > 0 then
                  t.in_progress <- Builds.remove id t.in_progress;
                Lwt.wakeup_later_exn set_result ex;
                finish_log ~set_log log
             )
        );
      tail_log >>!= fun () ->
      result

  let build ?switch t ?base ~id ~log fn =
    share_build ?switch t id ~log @@ fun ~cancelled set_log ->
    match Raw.result t.raw id with
    | Some dir ->
      log `Note (Fmt.strf "---> using cached result %S" dir);
      let now = Unix.(gmtime (gettimeofday ())) in
      Dao.set_used t.dao ~id ~now;
      let log_file = dir / "log" in
      begin
        if Sys.file_exists log_file then Build_log.of_saved log_file
        else Lwt.return (Build_log.empty)
      end >>= fun log ->
      Lwt.wakeup set_log log;
      Lwt_result.return id
    | None ->
      Raw.build t.raw ?base ~id (fun dir ->
          let log_file = dir / "log" in
          if Sys.file_exists log_file then Unix.unlink log_file;
          Build_log.create log_file >>= fun log ->
          Lwt.wakeup set_log log;
          fn ~cancelled ~log dir
        )
      >>= function
      | Ok () ->
        let now = Unix.(gmtime (gettimeofday () )) in
        Dao.add t.dao ?parent:(base :> string option) ~id ~now;
        Lwt_result.return id
      | Error _ as e ->
        Lwt.return e

  let result t id = Raw.result t.raw id

  let wrap raw =
    let db_dir = Raw.state_dir raw / "db" in
    Os.ensure_dir db_dir;
    let db = Db.of_dir (db_dir / "db.sqlite") in
    let dao = Dao.create db in
    { raw; dao; in_progress = Builds.empty }
end
