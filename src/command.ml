open Core_kernel.Std

module Unix     = Core_unix
module Filename = Core_filename

let unwords      xs = String.concat ~sep:" "    xs
let unparagraphs xs = String.concat ~sep:"\n\n" xs

exception Failed_to_parse_command_line of string

let die fmt = Printf.ksprintf (fun msg () -> raise (Failed_to_parse_command_line msg)) fmt

let help_screen_compare a b =
  match (a, b) with
  | (_, "[-help]")       -> -1 | ("[-help]",       _) -> 1
  | (_, "[-version]")    -> -1 | ("[-version]",    _) -> 1
  | (_, "[-build-info]") -> -1 | ("[-build-info]", _) -> 1
  | (_, "help")          -> -1 | ("help",        _)   -> 1
  | (_, "version")       -> -1 | ("version",     _)   -> 1
  | _ -> 0

module Format : sig
  module V1 : sig
    type t = {
      name    : string;
      doc     : string;
      aliases : string list;
    } [@@deriving sexp]

    val sort      : t list -> t list
    val to_string : t list -> string
  end
end = struct
  module V1 = struct
    type t = {
      name    : string;
      doc     : string;
      aliases : string list;
    } [@@deriving sexp]

    let sort ts =
      List.stable_sort ts ~cmp:(fun a b -> help_screen_compare a.name b.name)

    let word_wrap text width =
      let chunks = String.split text ~on:'\n' in
      List.concat_map chunks ~f:(fun text ->
        let words =
          String.split text ~on:' '
          |> List.filter ~f:(fun word -> not (String.is_empty word))
        in
        match
          List.fold words ~init:None ~f:(fun acc word ->
            Some begin
              match acc with
              | None -> ([], word)
              | Some (lines, line) ->
                (* efficiency is not a concern for the string lengths we expect *)
                let line_and_word = line ^ " " ^ word in
                if String.length line_and_word <= width then
                  (lines, line_and_word)
                else
                  (line :: lines, word)
            end)
        with
        | None -> []
        | Some (lines, line) -> List.rev (line :: lines))

    let%test_module "word wrap" = (module struct

      let%test _ = word_wrap "" 10 = []

      let short_word = "abcd"

      let%test _ = word_wrap short_word (String.length short_word) = [short_word]

      let%test _ = word_wrap "abc\ndef\nghi" 100 = ["abc"; "def"; "ghi"]

      let long_text =
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus \
         fermentum condimentum eros, sit amet pulvinar dui ultrices in."

      let%test _ = word_wrap long_text 1000 =
             ["Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus \
               fermentum condimentum eros, sit amet pulvinar dui ultrices in."]

      let%test _ = word_wrap long_text 39 =
      (*
               .........1.........2.........3.........4
               1234567890123456789012345678901234567890
             *)
             ["Lorem ipsum dolor sit amet, consectetur";
              "adipiscing elit. Vivamus fermentum";
              "condimentum eros, sit amet pulvinar dui";
              "ultrices in."]

      (* no guarantees: too-long words just overhang the soft bound *)
      let%test _ = word_wrap long_text 2 =
             ["Lorem"; "ipsum"; "dolor"; "sit"; "amet,"; "consectetur";
              "adipiscing"; "elit."; "Vivamus"; "fermentum"; "condimentum";
              "eros,"; "sit"; "amet"; "pulvinar"; "dui"; "ultrices"; "in."]

    end)

    let to_string ts =
      let n =
        List.fold ts ~init:0
          ~f:(fun acc t -> Int.max acc (String.length t.name))
      in
      let num_cols = 80 in (* anything more dynamic is likely too brittle *)
      let extend x =
        let slack = n - String.length x in
        x ^ String.make slack ' '
      in
      let lhs_width = n + 4 in
      let lhs_pad = String.make lhs_width ' ' in
      String.concat
        (List.map ts ~f:(fun t ->
           let rows k v =
             let vs = word_wrap v (num_cols - lhs_width) in
             match vs with
             | [] -> ["  "; k; "\n"]
             | v :: vs ->
               let first_line = ["  "; extend k; "  "; v; "\n"] in
               let rest_lines = List.map vs ~f:(fun v -> [lhs_pad; v; "\n"]) in
               List.concat (first_line :: rest_lines)
           in
           String.concat
             (List.concat
                (rows t.name t.doc
                 :: begin
                   match t.aliases with
                   | [] -> []
                   | [x] -> [rows "" (sprintf "(alias: %s)" x)]
                   | xs  ->
                     [rows "" (sprintf "(aliases: %s)" (String.concat ~sep:", " xs))]
                 end))))

  end
end

(* universal maps are used to pass around values between different bits
   of command line parsing code without having a huge impact on the
   types involved

   1. passing values from parsed args to command-line autocomplete functions
   2. passing special values to a base commands that request them in their spec
 * expanded subcommand path
 * args passed to the base command
 * help text for the base command
*)
module Env = struct
  include Univ_map

  let key_create name = Univ_map.Key.create ~name sexp_of_opaque
  let multi_add = Univ_map.Multi.add
  let set_with_default = Univ_map.With_default.set
end

module Completer = struct
  type t = (Env.t -> part:string -> string list) option

  let run_and_exit t env ~part : never_returns =
    Option.iter t ~f:(fun completions ->
      List.iter ~f:print_endline (completions env ~part));
    exit 0
end

module Arg_type = struct
  type 'a t = {
    parse : string -> ('a, exn) Result.t;
    complete : Completer.t;
    key : 'a Univ_map.Multi.Key.t option;
  }

  let create ?complete ?key of_string =
    let parse x = Result.try_with (fun () -> of_string x) in
    { parse; key; complete }

  let string             = create Fn.id
  let int                = create Int.of_string
  let char               = create Char.of_string
  let float              = create Float.of_string
  let bool               = create Bool.of_string
  let date               = create Date.of_string
  let time               = create Time.of_string_abs
  let time_ofday         = create Time.Ofday.Zoned.of_string
  let time_ofday_unzoned = create Time.Ofday.of_string
  let time_zone          = create Time.Zone.of_string
  let time_span          = create Time.Span.of_string

  let file ?key of_string =
    create ?key of_string ~complete:(fun _ ~part ->
      let completions =
        (* `compgen -f` handles some fiddly things nicely, e.g. completing "foo" and
           "foo/" appropriately. *)
        let command = sprintf "bash -c 'compgen -f %s'" part in
        let chan_in = Unix.open_process_in command in
        let completions = In_channel.input_lines chan_in in
        ignore (Unix.close_process_in chan_in);
        List.map (List.sort ~cmp:String.compare completions) ~f:(fun comp ->
          if Sys.is_directory comp
          then comp ^ "/"
          else comp)
      in
      match completions with
      | [dir] when String.is_suffix dir ~suffix:"/" ->
        (* If the only match is a directory, we fake out bash here by creating a bogus
           entry, which the user will never see - it forces bash to push the completion
           out to the slash. Then when the user hits tab again, they will be at the end
           of the line, at the directory with a slash and completion will continue into
           the subdirectory.
        *)
        [dir; dir ^ "x"]
      | _ -> completions
    )

  let of_map ?key map =
    create ?key
      ~complete:(fun _ ~part:prefix ->
        List.filter_map (Map.to_alist map) ~f:(fun (name, _) ->
          if String.is_prefix name ~prefix then Some name else None))
      (fun arg ->
         match Map.find map arg with
         | Some v -> v
         | None ->
           failwithf "valid arguments: {%s}" (String.concat ~sep:"," (Map.keys map)) ())

  let of_alist_exn ?key alist =
    match String.Map.of_alist alist with
    | `Ok map -> of_map ?key map
    | `Duplicate_key key ->
      failwithf "Command.Spec.Arg_type.of_alist_exn: duplicate key %s" key ()

  module Export = struct
    let string             = string
    let int                = int
    let char               = char
    let float              = float
    let bool               = bool
    let date               = date
    let time               = time
    let time_ofday         = time_ofday
    let time_ofday_unzoned = time_ofday_unzoned
    let time_zone          = time_zone
    let time_span          = time_span
    let file               = file Fn.id
  end
end

module Flag = struct

  module Internal = struct

    type action =
      | No_arg of (Env.t -> Env.t)
      | Arg    of (string -> Env.t -> Env.t) * Completer.t
      | Rest   of (string list -> unit)

    type t = {
      name : string;
      aliases : string list;
      action : action;
      doc : string;
      check_available : [ `Optional | `Required of (unit -> unit) ];
      name_matching : [`Prefix | `Full_match_required];
    }

    let wrap_if_optional t x =
      match t.check_available with
      | `Optional -> sprintf "[%s]" x
      | `Required _ -> x

    module Deprecated = struct
      (* flag help in the format of the old command. used for injection *)
      let help
            ({name; doc; aliases; action=_; check_available=_; name_matching=_ } as t)
        =
        if String.is_prefix doc ~prefix:" " then
          (name, String.lstrip doc)
          :: List.map aliases ~f:(fun x -> (x, sprintf "same as \"%s\"" name))
        else
          let (arg, doc) =
            match String.lsplit2 doc ~on:' ' with
            | None -> (doc, "")
            | Some pair -> pair
          in
          (wrap_if_optional t (name ^ " " ^ arg), String.lstrip doc)
          :: List.map aliases ~f:(fun x ->
            (wrap_if_optional t (x ^ " " ^ arg), sprintf "same as \"%s\"" name))
    end

    let align ({name; doc; aliases; action=_; check_available=_; name_matching=_ } as t) =
      let (name, doc) =
        match String.lsplit2 doc ~on:' ' with
        | None | Some ("", _) -> (name, String.strip doc)
        | Some (arg, doc) -> (name ^ " " ^ arg, doc)
      in
      let name = wrap_if_optional t name in
      { Format.V1.name; doc; aliases}

  end

  type 'a state = {
    action : Internal.action;
    read : unit -> 'a;
    optional : bool;
  }

  type 'a t = string -> 'a state

  let arg_flag name arg_type read write ~optional =
    { read; optional;
      action =
        let update arg env =
          match arg_type.Arg_type.parse arg with
          | Error exn ->
            die "failed to parse %s value %S.\n%s" name arg (Exn.to_string exn) ()
          | Ok arg ->
            write arg;
            match arg_type.Arg_type.key with
            | None -> env
            | Some key -> Env.multi_add env key arg
        in
        Arg (update, arg_type.Arg_type.complete);
    }

  let map_flag t ~f =
    fun input ->
      let {action; read; optional} = t input in
      { action;
        read = (fun () -> f (read ()));
        optional;
      }

  let write_option name v arg =
    match !v with
    | None -> v := Some arg
    | Some _ -> die "flag %s passed more than once" name ()

  let required_value ?default arg_type name ~optional =
    let v = ref None in
    let read () =
      match !v with
      | Some v -> v
      | None ->
        match default with
        | Some v -> v
        | None -> die "missing required flag: %s" name ()
    in
    let write arg = write_option name v arg in
    arg_flag name arg_type read write ~optional

  let required arg_type name =
    required_value arg_type name ~optional:false

  let optional_with_default default arg_type name =
    required_value ~default arg_type name ~optional:true

  let optional arg_type name =
    let v = ref None in
    let read () = !v in
    let write arg = write_option name v arg in
    arg_flag name arg_type read write ~optional:true

  let no_arg_general ~key_value ~deprecated_hook name =
    let v = ref false in
    let read () = !v in
    let write () =
      if !v then
        die "flag %s passed more than once" name ()
      else
        v := true
    in
    let action env =
      let env =
        Option.fold key_value ~init:env
          ~f:(fun env (key, value) ->
            Env.set_with_default env key value)
      in
      write ();
      env
    in
    let action =
      match deprecated_hook with
      | None -> action
      | Some f ->
        (fun x ->
           let env = action x in
           f ();
           env
        )
    in
    { read; action = No_arg action; optional = true }

  let no_arg name = no_arg_general name ~key_value:None ~deprecated_hook:None

  let no_arg_register ~key ~value name =
    no_arg_general name ~key_value:(Some (key, value)) ~deprecated_hook:None

  let listed arg_type name =
    let v = ref [] in
    let read () = List.rev !v in
    let write arg = v := arg :: !v in
    arg_flag name arg_type read write ~optional:true

  let one_or_more arg_type name =
    let q = Queue.create () in
    let read () =
      match Queue.to_list q with
      | first :: rest -> (first, rest)
      | [] -> die "missing required flag: %s" name ()
    in
    let write arg = Queue.enqueue q arg in
    arg_flag name arg_type read write ~optional:false

  let escape_general ~deprecated_hook _name =
    let cell = ref None in
    let action = (fun cmd_line -> cell := Some cmd_line) in
    let read () = !cell in
    let action =
      match deprecated_hook with
      | None -> action
      | Some f ->
        (fun x ->
           f x;
           action x
        )
    in
    { action = Rest action; read; optional = true }

  let no_arg_abort ~exit _name = {
    action = No_arg (fun _ -> never_returns (exit ()));
    optional = true;
    read = (fun () -> ());
  }

  let escape name = escape_general ~deprecated_hook:None name

  module Deprecated = struct
    let no_arg ~hook name = no_arg_general ~deprecated_hook:(Some hook) ~key_value:None name
    let escape ~hook      = escape_general ~deprecated_hook:(Some hook)
  end

end

module Path : sig
  type t
  val empty : t
  val root : string -> t
  val add : t -> subcommand:string -> t
  val commands : t -> string list
  val to_string : t -> string
  val to_string_dots : t -> string
  val pop_help : t -> t
  val length : t -> int
end = struct
  type t = string list
  let empty = []
  let root cmd = [Filename.basename cmd]
  let add t ~subcommand = subcommand :: t
  let commands t = List.rev t
  let to_string t = unwords (commands t)
  let length = List.length
  let pop_help = function
    | "help" :: t -> t
    | _ -> assert false
  let to_string_dots t =
    let t =
      match t with
      | [] -> []
      | last :: init -> last :: List.map init ~f:(Fn.const ".")
    in
    to_string t
end

module Anons = struct

  module Grammar : sig
    type t

    val zero : t
    val one : string -> t
    val many : t -> t
    val maybe : t -> t
    val concat : t list -> t
    val usage : t -> string
    val ad_hoc : usage:string -> t

    include Invariant.S with type t := t

    module Sexpable : sig
      module V1 : sig
        type t =
          | Zero
          | One of string
          | Many of t
          | Maybe of t
          | Concat of t list
          | Ad_hoc of string
        [@@deriving bin_io, compare, sexp]

        val usage : t -> string
      end

      type t = V1.t [@@deriving bin_io, compare, sexp]
    end
    val to_sexpable : t -> Sexpable.t

  end = struct

    module Sexpable = struct
      module V1 = struct
        type t =
          | Zero
          | One of string
          | Many of t
          | Maybe of t
          | Concat of t list
          | Ad_hoc of string
        [@@deriving bin_io, compare, sexp]

        let rec invariant t = Invariant.invariant [%here] t [%sexp_of: t] (fun () ->
          match t with
          | Zero -> ()
          | One _ -> ()
          | Many Zero -> failwith "Many Zero should be just Zero"
          | Many t -> invariant t
          | Maybe Zero -> failwith "Maybe Zero should be just Zero"
          | Maybe t -> invariant t
          | Concat [] | Concat [ _ ] -> failwith "Flatten zero and one-element Concat"
          | Concat ts -> List.iter ts ~f:invariant
          | Ad_hoc _ -> ())
        ;;

        let t_of_sexp sexp =
          let t = [%of_sexp: t] sexp in
          invariant t;
          t
        ;;

        let rec usage = function
          | Zero -> ""
          | One usage -> usage
          | Many Zero -> failwith "bug in command.ml"
          | Many (One _ as t) -> sprintf "[%s ...]" (usage t)
          | Many t -> sprintf "[(%s) ...]" (usage t)
          | Maybe Zero -> failwith "bug in command.ml"
          | Maybe t -> sprintf "[%s]" (usage t)
          | Concat ts -> String.concat ~sep:" " (List.map ts ~f:usage)
          | Ad_hoc usage -> usage
        ;;
      end
      include V1
    end

    type t = Sexpable.V1.t =
      | Zero
      | One of string
      | Many of t
      | Maybe of t
      | Concat of t list
      | Ad_hoc of string

    let to_sexpable = Fn.id
    let invariant = Sexpable.V1.invariant
    let usage = Sexpable.V1.usage

    let rec is_fixed_arity = function
      | Zero     -> true
      | One _    -> true
      | Many _   -> false
      | Maybe _  -> false
      | Ad_hoc _ -> false
      | Concat ts ->
        match List.rev ts with
        | [] -> failwith "bug in command.ml"
        | last :: others ->
          assert (List.for_all others ~f:is_fixed_arity);
          is_fixed_arity last
    ;;

    let zero = Zero
    let one name = One name

    let many = function
      | Zero -> Zero (* strange, but not non-sense *)
      | t ->
        if not (is_fixed_arity t)
        then failwithf "iteration of variable-length grammars such as %s is disallowed"
               (usage t) ();
        Many t
    ;;

    let maybe = function
      | Zero -> Zero (* strange, but not non-sense *)
      | t -> Maybe t
    ;;

    let concat = function
      | [] -> Zero
      | car :: cdr ->
        let car, cdr =
          List.fold cdr ~init:(car, []) ~f:(fun (t1, acc) t2 ->
            match t1, t2 with
            | Zero, t | t, Zero -> (t, acc)
            | _, _ ->
              if is_fixed_arity t1
              then (t2, t1 :: acc)
              else
                failwithf "the grammar %s for anonymous arguments \
                           is not supported because there is the possibility for \
                           arguments (%s) following a variable number of \
                           arguments (%s).  Supporting such grammars would complicate \
                           the implementation significantly."
                  (usage (Concat (List.rev (t2 :: t1 :: acc))))
                  (usage t2)
                  (usage t1)
                  ())
        in
        match cdr with
        | [] -> car
        | _ :: _ -> Concat (List.rev (car :: cdr))
    ;;

    let ad_hoc ~usage = Ad_hoc usage

  end

  module Parser : sig
    type 'a t
    val one : name:string -> 'a Arg_type.t -> 'a t
    val maybe : 'a t -> 'a option t
    val sequence : 'a t -> 'a list t
    val final_value : 'a t -> 'a
    val consume : 'a t -> string -> for_completion:bool -> (Env.t -> Env.t) * 'a t
    val complete : 'a t -> Env.t -> part:string -> never_returns
    module For_opening : sig
      val return : 'a -> 'a t
      val (<*>) : ('a -> 'b) t -> 'a t -> 'b t
      val (>>|) : 'a t -> ('a -> 'b) -> 'b t
    end
  end = struct

    type 'a t =
      | Done of 'a
      | More of 'a more
      (* A [Test] will (generally) return a [Done _] value if there is no more input and
         a [More] parser to use if there is any more input. *)
      | Test of (more:bool -> 'a t)
      (* If we're only completing, we can't pull values out, but we can still step through
         [t]s (which may have completion set up). *)
      | Only_for_completion of packed list

    and 'a more = {
      name : string;
      parse : string -> for_completion:bool -> (Env.t -> Env.t) * 'a t;
      complete : Completer.t;
    }

    and packed = Packed : 'a t -> packed

    let return a = Done a

    let pack_for_completion = function
      | Done _ -> [] (* won't complete or consume anything *)
      | More _ | Test _ as x -> [Packed x]
      | Only_for_completion ps -> ps

    let rec (<*>) tf tx =
      match tf with
      | Done f ->
        begin match tx with
        | Done x -> Done (f x)
        | Test test -> Test (fun ~more -> tf <*> test ~more)
        | More {name; parse; complete} ->
          let parse arg ~for_completion =
            let (upd, tx') = parse arg ~for_completion in
            (upd, tf <*> tx')
          in
          More {name; parse; complete}
        | Only_for_completion packed ->
          Only_for_completion packed
        end
      | Test test -> Test (fun ~more -> test ~more <*> tx)
      | More {name; parse; complete} ->
        let parse arg ~for_completion =
          let (upd, tf') = parse arg ~for_completion in
          (upd, tf' <*> tx)
        in
        More {name; parse; complete}
      | Only_for_completion packed ->
        Only_for_completion (packed @ pack_for_completion tx)

    let (>>|) t f = return f <*> t

    let one_more ~name {Arg_type.complete; parse = of_string; key} =
      let parse anon ~for_completion =
        match of_string anon with
        | Error exn ->
          if for_completion then
            (* we don't *really* care about this value, so just put in a dummy value so
               completion can continue *)
            (Fn.id, Only_for_completion [])
          else
            die "failed to parse %s value %S\n%s" name anon (Exn.to_string exn) ()
        | Ok v ->
          let update env =
            Option.fold key ~init:env ~f:(fun env key -> Env.multi_add env key v)
          in
          (update, Done v)
      in
      More {name; parse; complete}

    let one ~name arg_type =
      Test (fun ~more ->
        if more then
          one_more ~name arg_type
        else
          die "missing anonymous argument: %s" name ())

    let maybe t =
      Test (fun ~more ->
        if more
        then t >>| fun a -> Some a
        else return None)

    let sequence t =
      let rec loop =
        Test (fun ~more ->
          if more then
            return (fun v acc -> v :: acc) <*> t <*> loop
          else
            return [])
      in
      loop

    let rec final_value = function
      | Done a -> a
      | Test f -> final_value (f ~more:false)
      | More {name; _} -> die "missing anonymous argument: %s" name ()
      | Only_for_completion _ ->
        failwith "BUG: asked for final value when doing completion"

    let rec consume
      : type a . a t -> string -> for_completion:bool -> ((Env.t -> Env.t) * a t)
      = fun t arg ~for_completion ->
        match t with
        | Done _ -> die "too many anonymous arguments" ()
        | Test f -> consume (f ~more:true) arg ~for_completion
        | More {parse; _} -> parse arg ~for_completion
        | Only_for_completion packed ->
          match packed with
          | [] -> (Fn.id, Only_for_completion [])
          | (Packed t) :: rest ->
            let (upd, t) = consume t arg ~for_completion in
            (upd, Only_for_completion (pack_for_completion t @ rest))

    let rec complete
      : type a . a t -> Env.t -> part:string -> never_returns
      = fun t env ~part ->
        match t with
        | Done _ -> exit 0
        | Test f -> complete (f ~more:true) env ~part
        | More {complete; _} -> Completer.run_and_exit complete env ~part
        | Only_for_completion t ->
          match t with
          | [] -> exit 0
          | (Packed t) :: _ -> complete t env ~part

    module For_opening = struct
      let return = return
      let (<*>) = (<*>)
      let (>>|) = (>>|)
    end
  end

  open Parser.For_opening

  type 'a t = {
    p : 'a Parser.t;
    grammar : Grammar.t;
  }

  let t2 t1 t2 = {
    p =
      return (fun a1 a2 -> (a1, a2))
      <*> t1.p
      <*> t2.p
    ;
    grammar = Grammar.concat [t1.grammar; t2.grammar];
  }

  let t3 t1 t2 t3 = {
    p =
      return (fun a1 a2 a3 -> (a1, a2, a3))
      <*> t1.p
      <*> t2.p
      <*> t3.p
    ;
    grammar = Grammar.concat [t1.grammar; t2.grammar; t3.grammar];
  }

  let t4 t1 t2 t3 t4 = {
    p =
      return (fun a1 a2 a3 a4 -> (a1, a2, a3, a4))
      <*> t1.p
      <*> t2.p
      <*> t3.p
      <*> t4.p
    ;
    grammar = Grammar.concat [t1.grammar; t2.grammar; t3.grammar; t4.grammar];
  }

  let normalize str =
    (* Verify the string is not empty or surrounded by whitespace *)
    let strlen = String.length str in
    if strlen = 0 then failwith "Empty anonymous argument name provided";
    if String.(<>) (String.strip str) str then
      failwithf "argument name %S has surrounding whitespace" str ();
    (* If the string contains special surrounding characters, don't do anything *)
    let has_special_chars =
      let special_chars = Char.Set.of_list ['<'; '>'; '['; ']'; '('; ')'; '{'; '}'] in
      String.exists str ~f:(Set.mem special_chars)
    in
    if has_special_chars then str else String.uppercase str

  let%test _ = String.equal (normalize "file")   "FILE"
  let%test _ = String.equal (normalize "FiLe")   "FILE"
  let%test _ = String.equal (normalize "<FiLe>") "<FiLe>"
  let%test _ = String.equal (normalize "(FiLe)") "(FiLe)"
  let%test _ = String.equal (normalize "[FiLe]") "[FiLe]"
  let%test _ = String.equal (normalize "{FiLe}") "{FiLe}"
  let%test _ = String.equal (normalize "<file" ) "<file"
  let%test _ = String.equal (normalize "<fil>a") "<fil>a"
  let%test _ = try ignore (normalize ""        ); false with _ -> true
  let%test _ = try ignore (normalize " file "  ); false with _ -> true
  let%test _ = try ignore (normalize "file "   ); false with _ -> true
  let%test _ = try ignore (normalize " file"   ); false with _ -> true

  let (%:) name arg_type =
    let name = normalize name in
    { p = Parser.one ~name arg_type; grammar = Grammar.one name; }

  let map_anons t ~f = {
    p = t.p >>| f;
    grammar = t.grammar;
  }

  let maybe t = {
    p = Parser.maybe t.p;
    grammar = Grammar.maybe t.grammar;
  }

  let maybe_with_default default t =
    let t = maybe t in
    { t with p = t.p >>| fun v -> Option.value ~default v }

  let sequence t = {
    p = Parser.sequence t.p;
    grammar = Grammar.many t.grammar;
  }

  let non_empty_sequence t = t2 t (sequence t)

  module Deprecated = struct
    let ad_hoc ~usage_arg = {
      p = Parser.sequence (Parser.one ~name:"WILL NEVER BE PRINTED" Arg_type.string);
      grammar = Grammar.ad_hoc ~usage:usage_arg
    }
  end

end

module Cmdline = struct
  type t = Nil | Cons of string * t | Complete of string

  let of_list args =
    List.fold_right args ~init:Nil ~f:(fun arg args -> Cons (arg, args))

  let rec to_list = function
    | Nil -> []
    | Cons (x, xs) -> x :: to_list xs
    | Complete x -> [x]

  let rec ends_in_complete = function
    | Complete _ -> true
    | Nil -> false
    | Cons (_, args) -> ends_in_complete args

  let extend t ~extend ~path =
    if ends_in_complete t then t else begin
      let path_list = Option.value ~default:[] (List.tl (Path.commands path)) in
      of_list (to_list t @ extend path_list)
    end

end

let%test_module "Cmdline.extend" = (module struct
  let path_of_list subcommands =
    List.fold subcommands ~init:(Path.root "exe") ~f:(fun path subcommand ->
      Path.add path ~subcommand)

  let extend path =
    match path with
    | ["foo"; "bar"] -> ["-foo"; "-bar"]
    | ["foo"; "baz"] -> ["-foobaz"]
    | _ -> ["default"]

  let test path args expected =
    let expected = Cmdline.of_list expected in
    let observed =
      let path = path_of_list path in
      let args = Cmdline.of_list args in
      Cmdline.extend args ~extend ~path
    in
    Pervasives.(=) expected observed

  let%test _ = test ["foo"; "bar"] ["anon"; "-flag"] ["anon"; "-flag"; "-foo"; "-bar"]
  let%test _ = test ["foo"; "baz"] []                ["-foobaz"]
  let%test _ = test ["zzz"]        ["x"; "y"; "z"]   ["x"; "y"; "z"; "default"]
end)

module Key_type = struct
  type t = Subcommand | Flag
  let to_string = function
    | Subcommand -> "subcommand"
    | Flag       -> "flag"
end

let assert_no_underscores key_type flag_or_subcommand =
  if String.exists flag_or_subcommand ~f:(fun c -> c = '_') then
    failwithf "%s %s contains an underscore. Use a dash instead."
      (Key_type.to_string key_type) flag_or_subcommand ()

let normalize key_type key =
  assert_no_underscores key_type key;
  match key_type with
  | Key_type.Flag ->
    if String.equal key "-" then failwithf "invalid key name: %S" key ();
    if String.is_prefix ~prefix:"-" key then key else "-" ^ key
  | Key_type.Subcommand -> String.lowercase key

let lookup_expand alist prefix key_type =
  match
    List.filter alist ~f:(function
      | (key, (_, `Full_match_required)) -> String.(=) key prefix
      | (key, (_, `Prefix)) -> String.is_prefix key ~prefix)
  with
  | [(key, (data, _name_matching))] -> Ok (key, data)
  | [] ->
    Error (sprintf !"unknown %{Key_type} %s" key_type prefix)
  | matches ->
    match List.find matches ~f:(fun (key, _) -> String.(=) key prefix) with
    | Some (key, (data, _name_matching)) -> Ok (key, data)
    | None ->
      let matching_keys = List.map ~f:fst matches in
      Error (sprintf !"%{Key_type} %s is an ambiguous prefix: %s"
               key_type prefix (String.concat ~sep:", " matching_keys))

let lookup_expand_with_aliases map prefix key_type =
  let alist =
    List.concat_map (String.Map.data map) ~f:(fun flag ->
      let
        { Flag.Internal. name; aliases; action=_; doc=_; check_available=_; name_matching }
        = flag
      in
      let data = (flag, name_matching) in
      (name, data) :: List.map aliases ~f:(fun alias -> (alias, data)))
  in
  match List.find_a_dup alist ~compare:(fun (s1, _) (s2, _) -> String.compare s1 s2) with
  | None -> lookup_expand alist prefix key_type
  | Some (flag, _) -> failwithf "multiple flags named %s" flag ()

module Base = struct

  type t = {
    summary : string;
    readme : (unit -> string) option;
    flags : Flag.Internal.t String.Map.t;
    anons : Env.t -> ([`Parse_args] -> [`Run_main] -> unit) Anons.Parser.t;
    usage : Anons.Grammar.t;
  }

  module Deprecated = struct
    let subcommand_cmp_fst (a, _) (c, _) =
      help_screen_compare a c

    let flags_help ?(display_help_flags = true) t =
      let flags = String.Map.data t.flags in
      let flags =
        if display_help_flags
        then flags
        else List.filter flags ~f:(fun f -> f.name <> "-help")
      in
      List.concat_map ~f:Flag.Internal.Deprecated.help flags
  end

  let formatted_flags t =
    String.Map.data t.flags
    |> List.map ~f:Flag.Internal.align
    (* this sort puts optional flags after required ones *)
    |> List.sort ~cmp:(fun a b -> String.compare a.Format.V1.name b.name)
    |> Format.V1.sort

  let help_text ~path t =
    unparagraphs
      (List.filter_opt [
         Some t.summary;
         Some ("  " ^ Path.to_string path ^ " " ^ Anons.Grammar.usage t.usage);
         Option.map t.readme ~f:(fun readme -> readme ());
         Some "=== flags ===";
         Some (Format.V1.to_string (formatted_flags t));
       ])

  module Sexpable = struct

    module V2 = struct
      type anons =
        | Usage of string
        | Grammar of Anons.Grammar.Sexpable.V1.t
      [@@deriving sexp]

      type t = {
        summary : string;
        readme  : string sexp_option;
        anons   : anons;
        flags   : Format.V1.t list;
      } [@@deriving sexp]

    end

    module V1 = struct
      type t = {
        summary : string;
        readme  : string sexp_option;
        usage   : string;
        flags   : Format.V1.t list;
      } [@@deriving sexp]

      let to_latest { summary; readme; usage; flags; } = {
        V2.
        summary;
        readme;
        anons = Usage usage;
        flags;
      }

      let of_latest { V2.summary; readme; anons; flags; } = {
        summary;
        readme;
        usage =
          begin match anons with
          | Usage usage -> usage
          | Grammar grammar -> Anons.Grammar.Sexpable.V1.usage grammar
          end;
        flags;
      }

    end

    include V2
  end

  let to_sexpable t = {
    Sexpable.
    summary = t.summary;
    readme  = Option.map t.readme ~f:(fun readme -> readme ());
    anons   = Grammar (Anons.Grammar.to_sexpable t.usage);
    flags   = formatted_flags t;
  }

  let path_key = Env.key_create "path"
  let args_key = Env.key_create "args"
  let help_key = Env.key_create "help"

  let run t env ~path ~args =
    let help_text = lazy (help_text ~path t) in
    let env = Env.set env path_key path in
    let env = Env.set env args_key (Cmdline.to_list args) in
    let env = Env.set env help_key help_text in
    let rec loop env anons = function
      | Cmdline.Nil ->
        List.iter (String.Map.data t.flags) ~f:(fun flag ->
          match flag.check_available with
          | `Optional -> ()
          | `Required check -> check ());
        Anons.Parser.final_value anons
      | Cons (arg, args) ->
        if String.is_prefix arg ~prefix:"-"
           && not (String.equal arg "-") (* support the convention where "-" means stdin *)
        then begin
          let flag = arg in
          let (flag, { Flag.Internal. action; name=_; aliases=_; doc=_; check_available=_;
                       name_matching=_ }) =
            match lookup_expand_with_aliases t.flags flag Key_type.Flag with
            | Error msg -> die "%s" msg ()
            | Ok x -> x
          in
          match action with
          | No_arg f ->
            let env = f env in
            loop env anons args
          | Arg (f, comp) ->
            begin match args with
            | Nil -> die "missing argument for flag %s" flag ()
            | Cons (arg, rest) ->
              let env =
                try f arg env with
                | Failed_to_parse_command_line _ as e ->
                  if Cmdline.ends_in_complete rest then env else raise e
              in
              loop env anons rest
            | Complete part ->
              never_returns (Completer.run_and_exit comp env ~part)
            end
          | Rest f ->
            if Cmdline.ends_in_complete args then exit 0;
            f (Cmdline.to_list args);
            loop env anons Nil
        end else begin
          let (env_upd, anons) =
            Anons.Parser.consume anons arg ~for_completion:(Cmdline.ends_in_complete args)
          in
          let env = env_upd env in
          loop env anons args
        end
      | Complete part ->
        if String.is_prefix part ~prefix:"-" then begin
          List.iter (String.Map.keys t.flags) ~f:(fun name ->
            if String.is_prefix name ~prefix:part then print_endline name);
          exit 0
        end else
          never_returns (Anons.Parser.complete anons env ~part);
    in
    match Result.try_with (fun () -> loop env (t.anons env) args `Parse_args) with
    | Ok thunk -> thunk `Run_main
    | Error exn ->
      match exn with
      | Failed_to_parse_command_line _ when Cmdline.ends_in_complete args ->
        exit 0
      | Failed_to_parse_command_line msg ->
        print_endline (Lazy.force help_text);
        prerr_endline msg;
        exit 1
      | _ ->
        print_endline (Lazy.force help_text);
        raise exn

  module Spec = struct

    type ('a, 'b) t = {
      f : Env.t -> ('a -> 'b) Anons.Parser.t;
      usage : unit -> Anons.Grammar.t;
      flags : unit -> Flag.Internal.t list;
    }

    (* the reason that [param] is defined in terms of [t] rather than the other
       way round is that the delayed evaluation matters for sequencing of read/write
       operations on ref cells in the representation of flags *)
    type 'a param = { param : 'm. ('a -> 'm, 'm) t }

    open Anons.Parser.For_opening

    let app t1 t2 ~f = {
      f = (fun env ->
        return f
        <*> t1.f env
        <*> t2.f env
      );
      flags = (fun () -> t2.flags () @ t1.flags ());
      usage = (fun () -> Anons.Grammar.concat [t1.usage (); t2.usage ()]);
    }

    (* So sad.  We can't define [apply] in terms of [app] because of the value
       restriction. *)
    let apply pf px = {
      param = {
        f = (fun env ->
          return (fun mf mx k -> mf (fun f -> (mx (fun x -> k (f x)))))
          <*> pf.param.f env
          <*> px.param.f env
        );
        flags = (fun () -> px.param.flags () @ pf.param.flags ());
        usage = (fun () -> Anons.Grammar.concat [pf.param.usage (); px.param.usage ()]);
      }
    }

    let (++) t1 t2 = app t1 t2 ~f:(fun f1 f2 x -> f2 (f1 x))
    let (+>) t1 p2 = app t1 p2.param ~f:(fun f1 f2 x -> f2 (f1 x))
    let (+<) t1 p2 = app p2.param t1 ~f:(fun f2 f1 x -> f1 (f2 x))

    let step f = {
      f = (fun _env -> return f);
      flags = (fun () -> []);
      usage = (fun () -> Anons.Grammar.zero);
    }

    let empty : 'm. ('m, 'm) t = {
      f = (fun _env -> return Fn.id);
      flags = (fun () -> []);
      usage = (fun () -> Anons.Grammar.zero);
    }

    let const v =
      { param =
          { f = (fun _env -> return (fun k -> k v));
            flags = (fun () -> []);
            usage = (fun () -> Anons.Grammar.zero); } }

    let map p ~f =
      { param =
          { f =
              (fun env -> p.param.f env >>| fun c k -> c (fun v -> k (f v)));
            flags = p.param.flags;
            usage = p.param.usage; } }

    let wrap f t =
      { f =
          (fun env -> t.f env >>| fun run main -> f ~run ~main);
        flags = t.flags;
        usage = t.usage; }

    let of_params params =
      let t = params.param in
      { f = (fun env -> t.f env >>| fun run main -> run Fn.id main);
        flags = t.flags;
        usage = t.usage; }

    let to_params (t : ('a, 'b) t) : ('a -> 'b) param =
      { param = {
          f = (fun env -> t.f env >>| fun f k -> k f);
          flags = t.flags;
          usage = t.usage;
        }
      }

    let to_param t main = map (to_params t) ~f:(fun k -> k main)

    let lookup key =
      { param =
          { f = (fun env -> return (fun m -> m (Env.find_exn env key)));
            flags = (fun () -> []);
            usage = (fun () -> Anons.Grammar.zero); } }

    let path : Path.t        param = lookup path_key
    let args : string list   param = lookup args_key
    let help : string Lazy.t param = lookup help_key

    let env =
      { param =
          { f = (fun env -> return (fun m -> m env));
            flags = (fun () -> []);
            usage = (fun () -> Anons.Grammar.zero); } }

    include struct
      module Arg_type = Arg_type
      include Arg_type.Export
    end

    include struct
      open Anons
      type 'a anons = 'a t
      let (%:)               = (%:)
      let map_anons          = map_anons
      let maybe              = maybe
      let maybe_with_default = maybe_with_default
      let sequence           = sequence
      let non_empty_sequence = non_empty_sequence
      let t2                 = t2
      let t3                 = t3
      let t4                 = t4

      let anon spec =
        Anons.Grammar.invariant spec.grammar;
        {
          param = {
            f = (fun _env -> spec.p >>| fun v k -> k v);
            flags = (fun () -> []);
            usage = (fun () -> spec.grammar);
          }
        }
    end

    include struct
      open Flag
      type 'a flag = 'a t
      let map_flag              = map_flag
      let escape                = escape
      let listed                = listed
      let one_or_more           = one_or_more
      let no_arg                = no_arg
      let no_arg_register       = no_arg_register
      let no_arg_abort          = no_arg_abort
      let optional              = optional
      let optional_with_default = optional_with_default
      let required              = required

      let flag ?(aliases = []) ?full_flag_required name mode ~doc =
        let normalize flag = normalize Key_type.Flag flag in
        let name = normalize name in
        let aliases = List.map ~f:normalize aliases in
        let {read; action; optional} = mode name in
        let check_available =
          if optional then `Optional else `Required (fun () -> ignore (read ()))
        in
        let name_matching =
          if Option.is_some full_flag_required then `Full_match_required else `Prefix
        in
        { param =
            { f = (fun _env -> return (fun k -> k (read ())));
              flags = (fun () -> [{ name; aliases; doc; action;
                                    check_available; name_matching }]);
              usage = (fun () -> Anons.Grammar.zero);
            }
        }

      include Applicative.Make (struct
        type nonrec 'a t = 'a param
        let return = const
        let apply = apply
        let map = `Custom map
      end)

      let pair = both
    end

    let flags_of_args_exn args =
      List.fold args ~init:empty ~f:(fun acc (name, spec, doc) ->
        let gen f flag_type = step (fun m x -> f x; m) +> flag name flag_type ~doc in
        let call f arg_type = gen (fun x -> Option.iter x ~f) (optional arg_type) in
        let set r arg_type = call (fun x -> r := x) arg_type in
        let set_bool r b = gen (fun passed -> if passed then r := b) no_arg in
        acc ++ begin
          match spec with
          | Arg.Unit f -> gen (fun passed -> if passed then f ()) no_arg
          | Arg.Set   r -> set_bool r true
          | Arg.Clear r -> set_bool r false
          | Arg.String     f -> call f string
          | Arg.Set_string r -> set  r string
          | Arg.Int        f -> call f int
          | Arg.Set_int    r -> set  r int
          | Arg.Float      f -> call f float
          | Arg.Set_float  r -> set  r float
          | Arg.Bool       f -> call f bool
          | Arg.Symbol (syms, f) ->
            let arg_type =
              Arg_type.of_alist_exn (List.map syms ~f:(fun sym -> (sym, sym)))
            in
            call f arg_type
          | Arg.Rest f -> gen (fun x -> Option.iter x ~f:(List.iter ~f)) escape
          | Arg.Tuple _ ->
            failwith "Arg.Tuple is not supported by Command.Spec.flags_of_args_exn"
        end)

    module Deprecated = struct
      include Flag.Deprecated
      include Anons.Deprecated
    end

  end
end

let group_or_exec_help_text ~show_flags ~path ~summary ~readme ~format_list =
  unparagraphs (List.filter_opt [
    Some summary;
    Some (String.concat ["  "; Path.to_string path; " SUBCOMMAND"]);
    Option.map readme ~f:(fun readme -> readme ());
    Some
      (if show_flags
       then "=== subcommands and flags ==="
       else "=== subcommands ===");
    Some (Format.V1.to_string format_list);
  ])
;;

module Group = struct
  type 'a t = {
    summary     : string;
    readme      : (unit -> string) option;
    subcommands : (string * 'a) list;
    body        : (path:string list -> unit) option;
  }

  let help_text ~show_flags ~to_format_list ~path t =
    group_or_exec_help_text
      ~show_flags
      ~path
      ~readme:t.readme
      ~summary:t.summary
      ~format_list:(to_format_list t)
  ;;

  module Sexpable = struct
    module V1 = struct
      type 'a t = {
        summary     : string;
        readme      : string sexp_option;
        subcommands : (string, 'a) List.Assoc.t;
      } [@@deriving sexp]

      let map t ~f = { t with subcommands = List.Assoc.map t.subcommands ~f }
    end
    include V1
  end

  let to_sexpable ~subcommand_to_sexpable t =
    { Sexpable.
      summary = t.summary;
      readme  = Option.map ~f:(fun readme -> readme ()) t.readme;
      subcommands = List.Assoc.map ~f:subcommand_to_sexpable t.subcommands;
    }
end

let abs_path ~dir path =
  if Filename.is_absolute path
  then path
  else Filename.concat dir path
;;

let%test_unit _ = [
  "/",    "./foo",         "/foo";
  "/tmp", "/usr/bin/grep", "/usr/bin/grep";
  "/foo", "bar",           "/foo/bar";
  "foo",  "bar",           "foo/bar";
  "foo",  "../bar",        "foo/../bar";
] |> List.iter ~f:(fun (dir, path, expected) ->
  [%test_eq: string] (abs_path ~dir path) expected)

module Exec = struct
  type t = {
    summary     : string;
    readme      : (unit -> string) option;
    (* If [path_to_exe] is relative, interpret w.r.t. [working_dir] *)
    working_dir : string;
    path_to_exe : string;
  }

  module Sexpable = struct
    module V2 = struct
      type t = {
        summary     : string;
        readme      : string sexp_option;
        working_dir : string;
        path_to_exe : string;
      } [@@deriving sexp]
    end

    module V1 = struct
      type t = {
        summary     : string;
        readme      : string sexp_option;
        (* [path_to_exe] must be absolute. *)
        path_to_exe : string;
      } [@@deriving sexp]

      let to_latest t : V2.t = {
        summary = t.summary;
        readme = t.readme;
        working_dir = "/";
        path_to_exe = t.path_to_exe;
      }

      let of_latest (t : V2.t) = {
        summary = t.summary;
        readme = t.readme;
        path_to_exe = abs_path ~dir:t.working_dir t.path_to_exe;
      }
    end

    include V2
  end

  let to_sexpable t =
    { Sexpable.
      summary  = t.summary;
      readme   = Option.map ~f:(fun readme -> readme ()) t.readme;
      working_dir = t.working_dir;
      path_to_exe = t.path_to_exe;
    }

  let exec_with_args t ~args =
    let prog = abs_path ~dir:t.working_dir t.path_to_exe in
    never_returns (Unix.exec ~prog ~args:(prog :: args) ())
  ;;

  let help_text ~show_flags ~to_format_list ~path t =
    group_or_exec_help_text
      ~show_flags
      ~path
      ~readme:(t.readme)
      ~summary:(t.summary)
      ~format_list:(to_format_list t)
  ;;
end

(* A proxy command is the structure of an Exec command obtained by running it in a
   special way *)
module Proxy = struct

  module Kind = struct
    type 'a t =
      | Base  of Base.Sexpable.t
      | Group of 'a Group.Sexpable.t
      | Exec  of Exec.Sexpable.t
  end

  type t = {
    working_dir        : string;
    path_to_exe        : string;
    path_to_subcommand : string list;
    kind               : t Kind.t;
  }

  let get_summary t =
    match t.kind with
    | Base  b -> b.summary
    | Group g -> g.summary
    | Exec  e -> e.summary

  let get_readme t =
    match t.kind with
    | Base  b -> b.readme
    | Group g -> g.readme
    | Exec  e -> e.readme

  let help_text ~show_flags ~to_format_list ~path t =
    group_or_exec_help_text
      ~show_flags
      ~path
      ~readme:(get_readme t |> Option.map ~f:const)
      ~summary:(get_summary t)
      ~format_list:(to_format_list t)
end

type t =
  | Base  of Base.t
  | Group of t Group.t
  | Exec  of Exec.t
  | Proxy of Proxy.t

module Sexpable = struct

  let supported_versions : int Queue.t = Queue.create ()
  let add_version n = Queue.enqueue supported_versions n

  module V2 = struct
    let () = add_version 2

    type t =
      | Base of Base.Sexpable.V2.t
      | Group of t Group.Sexpable.V1.t
      | Exec  of Exec.Sexpable.V2.t
    [@@deriving sexp]

    let to_latest = Fn.id
    let of_latest = Fn.id

  end

  module Latest = V2

  module V1 = struct
    let () = add_version 1

    type t =
      | Base  of Base.Sexpable.V1.t
      | Group of t Group.Sexpable.V1.t
      | Exec  of Exec.Sexpable.V1.t
    [@@deriving sexp]

    let rec to_latest : t -> Latest.t = function
      | Base b -> Base (Base.Sexpable.V1.to_latest b)
      | Group g -> Group (Group.Sexpable.V1.map g ~f:to_latest)
      | Exec e -> Exec (Exec.Sexpable.V1.to_latest e)
    ;;

    let rec of_latest : Latest.t -> t = function
      | Base b -> Base (Base.Sexpable.V1.of_latest b)
      | Group g -> Group (Group.Sexpable.V1.map g ~f:of_latest)
      | Exec e -> Exec (Exec.Sexpable.V1.of_latest e)
    ;;

  end

  module Internal : sig
    type t [@@deriving sexp]
    val of_latest : version_to_use:int -> Latest.t -> t
    val to_latest : t -> Latest.t
  end = struct
    type t =
      | V1 of V1.t
      | V2 of V2.t
    [@@deriving sexp]

    let to_latest = function
      | V1 t -> V1.to_latest t
      | V2 t -> V2.to_latest t

    let of_latest ~version_to_use latest =
      match version_to_use with
      | 1 -> V1 (V1.of_latest latest)
      | 2 -> V2 (V2.of_latest latest)
      | other -> failwiths "unsupported version_to_use" other [%sexp_of: int]
    ;;

  end

  include Latest

  let supported_versions = Int.Set.of_list (Queue.to_list supported_versions)

  let get_summary = function
    | Base  x -> x.summary
    | Group x -> x.summary
    | Exec  x -> x.summary

  let extraction_var = "COMMAND_OUTPUT_HELP_SEXP"

  let of_external ~working_dir ~path_to_exe =
    let process_info =
      Unix.create_process_env () ~args:[]
        ~prog:(abs_path ~dir:working_dir path_to_exe)
        ~env:(`Extend [
          ( extraction_var
          , supported_versions |> Int.Set.sexp_of_t |> Sexp.to_string
          )
        ])
    in
    (* We aren't writing to the process's stdin or reading from the process's stderr, so
       close them early.  That way if we open a process that isn't behaving how we
       expect, it at least won't block on these file descriptors. *)
    Unix.close process_info.stdin;
    Unix.close process_info.stderr;
    let t =
      process_info.stdout
      |> Unix.in_channel_of_descr
      |> In_channel.input_all
      |> String.strip
      |> Sexp.of_string
      |> Internal.t_of_sexp
      |> Internal.to_latest
    in
    Unix.close process_info.stdout;
    ignore (Unix.wait (`Pid process_info.pid));
    t

  let rec find (t : t) ~path_to_subcommand =
    match path_to_subcommand with
    | [] -> t
    | sub :: subs ->
      match t with
      | Base _ -> failwithf "unexpected subcommand %S" sub ()
      | Exec {path_to_exe; working_dir; _} ->
        find (of_external ~working_dir ~path_to_exe) ~path_to_subcommand:(sub :: subs)
      | Group g ->
        match List.Assoc.find g.subcommands sub with
        | None -> failwithf "unknown subcommand %S" sub ()
        | Some t -> find t ~path_to_subcommand:subs

end

let rec sexpable_of_proxy proxy =
  match proxy.Proxy.kind with
  | Base  base  -> Sexpable.Base base
  | Exec  exec  -> Sexpable.Exec exec
  | Group group ->
    Sexpable.Group
      { group with
        subcommands =
          List.map group.subcommands ~f:(fun (str, proxy) ->
            (str, sexpable_of_proxy proxy))
      }

let rec to_sexpable = function
  | Base  base  -> Sexpable.Base  (Base.to_sexpable base)
  | Exec  exec  -> Sexpable.Exec  (Exec.to_sexpable exec)
  | Proxy proxy -> sexpable_of_proxy proxy
  | Group group ->
    Sexpable.Group (Group.to_sexpable ~subcommand_to_sexpable:to_sexpable group)

type ('main, 'result) basic_command
  =  summary:string
  -> ?readme:(unit -> string)
  -> ('main, unit -> 'result) Base.Spec.t
  -> 'main
  -> t

let get_summary = function
  | Base  base  -> base.summary
  | Group group -> group.summary
  | Exec  exec  -> exec.summary
  | Proxy proxy -> Proxy.get_summary proxy

let extend_exn ~mem ~add map key_type ~key data =
  if mem map key then
    failwithf "there is already a %s named %s" (Key_type.to_string key_type) key ();
  add map ~key ~data

let extend_map_exn map key_type ~key data =
  extend_exn map key_type ~key data ~mem:Map.mem ~add:Map.add

let extend_alist_exn alist key_type ~key data =
  extend_exn alist key_type ~key data
    ~mem:(fun alist key -> List.Assoc.mem alist key ~equal:String.equal)
    ~add:(fun alist ~key ~data -> List.Assoc.add alist key data ~equal:String.equal)

module Bailout_dump_flag = struct
  let add base ~name ~aliases ~text ~text_summary =
    let flags = base.Base.flags in
    let flags =
      extend_map_exn flags Key_type.Flag ~key:name
        { name;
          aliases;
          check_available = `Optional;
          action = No_arg (fun env -> print_endline (text env); exit 0);
          doc = sprintf " print %s and exit" text_summary;
          name_matching = `Prefix;
        }
    in
    { base with Base.flags }
end

let basic ~summary ?readme {Base.Spec.usage; flags; f} main =
  let flags = flags () in
  let usage = usage () in
  let anons env =
    let open Anons.Parser.For_opening in
    f env
    >>| fun k `Parse_args ->
    let thunk = k main in
    fun `Run_main -> thunk ()
  in
  let flags =
    match
      String.Map.of_alist (List.map flags ~f:(fun flag -> (flag.name, flag)))
    with
    | `Duplicate_key flag -> failwithf "multiple flags named %s" flag ()
    | `Ok map ->
      begin (* check for alias collision, too *)
        match
          String.Map.of_alist
            (List.concat_map flags
               ~f:(fun { name; aliases; action = _; doc = _; check_available = _;
                         name_matching = _ } ->
                    (name, ()) :: List.map aliases ~f:(fun alias -> (alias, ()))))
        with
        | `Duplicate_key x -> failwithf "multiple flags or aliases named %s" x ()
        | `Ok _ -> ()
      end;
      map
  in
  let base = { Base.summary; readme; usage; flags; anons } in
  let base =
    Bailout_dump_flag.add base ~name:"-help" ~aliases:["-?"]
      ~text_summary:"this help text"
      ~text:(fun env -> Lazy.force (Env.find_exn env Base.help_key))
  in
  Base base

let subs_key : (string * t) list Env.Key.t = Env.key_create "subcommands"

let gather_help ~recursive ~show_flags ~expand_dots sexpable =
  let rec loop rpath acc sexpable =
    let string_of_path =
      if expand_dots
      then Path.to_string
      else Path.to_string_dots
    in
    let gather_exec rpath acc {Exec.Sexpable.working_dir; path_to_exe; _} =
      loop rpath acc (Sexpable.of_external ~working_dir ~path_to_exe)
    in
    let gather_group rpath acc subs =
      let subs =
        if recursive && rpath <> Path.empty
        then List.Assoc.remove ~equal:String.(=) subs "help"
        else subs
      in
      let alist =
        List.stable_sort subs ~cmp:(fun a b -> help_screen_compare (fst a) (fst b))
      in
      List.fold alist ~init:acc ~f:(fun acc (subcommand, t) ->
        let rpath = Path.add rpath ~subcommand in
        let key = string_of_path rpath in
        let doc = Sexpable.get_summary t in
        let acc = Fqueue.enqueue acc { Format.V1. name = key; doc; aliases = [] } in
        if recursive
        then loop rpath acc t
        else acc)
    in
    match sexpable with
    | Sexpable.Exec exec   -> gather_exec rpath acc exec
    | Sexpable.Group group -> gather_group rpath acc group.Group.Sexpable.subcommands
    | Sexpable.Base base   ->
      if show_flags then begin
        base.Base.Sexpable.flags
        |> List.filter ~f:(fun fmt -> fmt.Format.V1.name <> "[-help]")
        |> List.fold ~init:acc ~f:(fun acc fmt ->
          let rpath = Path.add rpath ~subcommand:fmt.Format.V1.name in
          let fmt = { fmt with Format.V1.name = string_of_path rpath } in
          Fqueue.enqueue acc fmt)
      end else
        acc
  in
  loop Path.empty Fqueue.empty sexpable
;;

let help_subcommand ~summary ~readme =
  basic ~summary:"explain a given subcommand (perhaps recursively)"
    Base.Spec.(
      empty
      +> flag "-recursive"   no_arg ~doc:" show subcommands of subcommands, etc."
      +> flag "-flags"       no_arg ~doc:" show flags as well in recursive help"
      +> flag "-expand-dots" no_arg ~doc:" expand subcommands in recursive help"
      +> path
      +> env
      +> anon (maybe ("SUBCOMMAND" %: string))
    )
    (fun recursive show_flags expand_dots path (env : Env.t) cmd_opt () ->
       let subs =
         match Env.find env subs_key with
         | Some subs -> subs
         | None -> assert false (* maintained by [dispatch] *)
       in
       let path =
         let path = Path.pop_help path in
         Option.fold cmd_opt ~init:path
           ~f:(fun path subcommand -> Path.add path ~subcommand)
       in
       let format_list t =
         gather_help ~recursive ~show_flags ~expand_dots (to_sexpable t)
         |> Fqueue.to_list
       in
       let group_help_text group =
         let to_format_list g = format_list (Group g) in
         Group.help_text ~show_flags ~to_format_list ~path group
       in
       let exec_help_text exec =
         let to_format_list e = format_list (Exec e) in
         Exec.help_text ~show_flags ~to_format_list ~path exec
       in
       let proxy_help_text proxy =
         let to_format_list p = format_list (Proxy p) in
         Proxy.help_text ~show_flags ~to_format_list ~path proxy
       in
       let text =
         match cmd_opt with
         | None ->
           group_help_text {
             readme;
             summary;
             subcommands = subs;
             body = None;
           }
         | Some cmd ->
           match List.Assoc.find subs cmd ~equal:String.equal with
           | None ->
             die "unknown subcommand %s for command %s" cmd (Path.to_string path) ()
           | Some t ->
             match t with
             | Exec  exec  -> exec_help_text exec
             | Group group -> group_help_text group
             | Base  base  -> Base.help_text ~path base
             | Proxy proxy -> proxy_help_text proxy
       in
       print_endline text)

let group ~summary ?readme ?preserve_subcommand_order ?body alist =
  let alist =
    List.map alist ~f:(fun (name, t) -> (normalize Key_type.Subcommand name, t))
  in
  let subcommands =
    match String.Map.of_alist alist with
    | `Duplicate_key name -> failwithf "multiple subcommands named %s" name ()
    | `Ok map ->
      match preserve_subcommand_order with
      | Some () -> alist
      | None -> Map.to_alist map
  in
  Group {summary; readme; subcommands; body}

let exec ~summary ?readme ~path_to_exe () =
  let working_dir = Filename.dirname Sys.executable_name in
  let path_to_exe =
    match path_to_exe with
    | `Absolute p        ->
      if not (Filename.is_absolute p)
      then failwith "Path passed to `Absolute must be absolute"
      else p
    | `Relative_to_me p ->
      if not (Filename.is_relative p)
      then failwith "Path passed to `Relative_to_me must be relative"
      else p
  in
  Exec {summary; readme; working_dir; path_to_exe}

module Shape = struct
  module Flag_info = struct

    type t = Format.V1.t = {
      name : string;
      doc : string;
      aliases : string list;
    } [@@deriving bin_io, compare, fields, sexp]

  end

  module Base_info = struct

    type grammar = Anons.Grammar.Sexpable.V1.t =
      | Zero
      | One of string
      | Many of grammar
      | Maybe of grammar
      | Concat of grammar list
      | Ad_hoc of string
    [@@deriving bin_io, compare, sexp]

    type anons = Base.Sexpable.V2.anons =
      | Usage of string
      | Grammar of grammar
    [@@deriving bin_io, compare, sexp]

    type t = Base.Sexpable.V2.t = {
      summary : string;
      readme  : string sexp_option;
      anons   : anons;
      flags   : Flag_info.t list;
    } [@@deriving bin_io, compare, fields, sexp]

  end

  module Group_info = struct

    type 'a t = 'a Group.Sexpable.V1.t = {
      summary     : string;
      readme      : string sexp_option;
      subcommands : (string, 'a) List.Assoc.t;
    } [@@deriving bin_io, compare, fields, sexp]

    let map = Group.Sexpable.V1.map

  end

  module Exec_info = struct

    type t = Exec.Sexpable.V2.t = {
      summary     : string;
      readme      : string sexp_option;
      working_dir : string;
      path_to_exe : string;
    } [@@deriving bin_io, compare, fields, sexp]

  end

  module T = struct

    type t =
      | Basic of Base_info.t
      | Group of t Group_info.t
      | Exec of Exec_info.t * (unit -> t)

  end

  module Fully_forced = struct

    type t =
      | Basic of Base_info.t
      | Group of t Group_info.t
      | Exec of Exec_info.t * t
    [@@deriving bin_io, compare, sexp]

    let rec create : T.t -> t = function
      | Basic b -> Basic b
      | Group g -> Group (Group_info.map g ~f:create)
      | Exec (e, f) -> Exec (e, create (f ()))

  end

  include T

end

let rec proxy_of_sexpable sexpable ~working_dir ~path_to_exe ~path_to_subcommand =
  let kind =
    match (sexpable : Sexpable.t) with
    | Base  b -> Proxy.Kind.Base b
    | Exec  e -> Proxy.Kind.Exec e
    | Group g ->
      Proxy.Kind.Group
        { g with
          subcommands =
            List.map g.subcommands ~f:(fun (str, sexpable) ->
              let path_to_subcommand = path_to_subcommand @ [str] in
              let proxy =
                proxy_of_sexpable sexpable ~working_dir ~path_to_exe ~path_to_subcommand
              in
              (str, proxy))
        }
  in
  { Proxy. working_dir; path_to_exe; path_to_subcommand; kind }

let proxy_of_exe ~working_dir path_to_exe =
  let sexpable = Sexpable.of_external ~working_dir ~path_to_exe in
  proxy_of_sexpable sexpable ~working_dir ~path_to_exe ~path_to_subcommand:[]

let rec shape_of_proxy proxy : Shape.t =
  match proxy.Proxy.kind with
  | Base  b -> Basic b
  | Group g -> Group { g with subcommands = List.Assoc.map g.subcommands ~f:shape_of_proxy }
  | Exec  e ->
    let f () = shape_of_proxy (proxy_of_exe ~working_dir:e.working_dir e.path_to_exe) in
    Exec (e, f)
;;

let rec shape t : Shape.t =
  match t with
  | Base  b -> Basic (Base.to_sexpable b)
  | Group g -> Group (Group.to_sexpable ~subcommand_to_sexpable:shape g)
  | Proxy p -> shape_of_proxy p
  | Exec  e ->
    let f () = shape_of_proxy (proxy_of_exe ~working_dir:e.working_dir e.path_to_exe) in
    Exec (Exec.to_sexpable e, f)
;;

module Version_info = struct
  let print_version ~version =
    (* [version] was space delimited at some point and newline delimited
       at another.  We always print one (repo, revision) pair per line
       and ensure sorted order *)
    String.split version ~on:' '
    |> List.concat_map ~f:(String.split ~on:'\n')
    |> List.sort ~cmp:String.compare
    |> List.iter ~f:print_endline

  let print_build_info ~build_info = print_endline build_info

  let command ~version ~build_info =
    basic ~summary:"print version information"
      Base.Spec.(
        empty
        +> flag "-version" no_arg ~doc:" print the version of this build"
        +> flag "-build-info" no_arg ~doc:" print build info for this build"
      )
      (fun version_flag build_info_flag ->
         begin
           if build_info_flag then print_build_info ~build_info
           else if version_flag then print_version ~version
           else (print_build_info ~build_info; print_version ~version)
         end;
         exit 0)

  let add
        ~version
        ~build_info
        unversioned =
    match unversioned with
    | Base base ->
      let base =
        Bailout_dump_flag.add base ~name:"-version" ~aliases:[]
          ~text_summary:"the version of this build" ~text:(Fn.const version)
      in
      let base =
        Bailout_dump_flag.add base ~name:"-build-info" ~aliases:[]
          ~text_summary:"info about this build" ~text:(Fn.const build_info)
      in
      Base base
    | Group group ->
      let subcommands =
        extend_alist_exn group.Group.subcommands Key_type.Subcommand ~key:"version"
          (command ~version ~build_info)
      in
      Group { group with Group.subcommands }
    | Proxy proxy -> Proxy proxy
    | Exec  exec  -> Exec  exec

end

(* clear the setting of environment variable associated with command-line
   completion and recursive help so that subprocesses don't see them. *)
let getenv_and_clear var =
  let value = Core_sys.getenv var in
  if Option.is_some value then Unix.unsetenv var;
  value
;;

(* This script works in both bash (via readarray) and zsh (via read -A).  If you change
   it, please test in both bash and zsh.  It does not work in ksh (unexpected null byte)
   and tcsh (different function syntax). *)
let dump_autocomplete_function () =
  let fname = sprintf "_jsautocom_%s" (Pid.to_string (Unix.getpid ())) in
  printf
    "function %s {
  export COMP_CWORD
  COMP_WORDS[0]=%s
  if type readarray > /dev/null
  then readarray -t COMPREPLY < <(\"${COMP_WORDS[@]}\")
  else IFS=\"\n\" read -d \"\x00\" -A COMPREPLY < <(\"${COMP_WORDS[@]}\")
  fi
}
complete -F %s %s
%!" fname Sys.argv.(0) fname Sys.argv.(0)
;;

let dump_help_sexp ~supported_versions t ~path_to_subcommand =
  Int.Set.inter Sexpable.supported_versions supported_versions
  |> Int.Set.max_elt
  |> function
  | None ->
    failwiths "Couldn't choose a supported help output version for Command.exec \
               from the given supported versions."
      Sexpable.supported_versions Int.Set.sexp_of_t;
  | Some version_to_use ->
    to_sexpable t
    |> Sexpable.find ~path_to_subcommand
    |> Sexpable.Internal.of_latest ~version_to_use
    |> Sexpable.Internal.sexp_of_t
    |> Sexp.to_string
    |> print_string
;;

let handle_environment t ~argv =
  match argv with
  | [] -> failwith "missing executable name"
  | cmd :: args ->
    Option.iter (getenv_and_clear Sexpable.extraction_var)
      ~f:(fun version ->
        let supported_versions = Sexp.of_string version |> Int.Set.t_of_sexp in
        dump_help_sexp ~supported_versions t ~path_to_subcommand:args;
        exit 0);
    Option.iter (getenv_and_clear "COMMAND_OUTPUT_INSTALLATION_BASH")
      ~f:(fun _ ->
        dump_autocomplete_function ();
        exit 0);
    (cmd, args)
;;

let set_comp_cword new_value =
  let new_value = Int.to_string new_value in
  Unix.putenv ~key:"COMP_CWORD" ~data:new_value
;;

let process_args ~cmd ~args =
  let maybe_comp_cword =
    getenv_and_clear "COMP_CWORD"
    |> Option.map ~f:Int.of_string
  in
  let args =
    match maybe_comp_cword with
    | None -> Cmdline.of_list args
    | Some comp_cword ->
      let args = List.take (args @ [""]) comp_cword in
      List.fold_right args ~init:Cmdline.Nil ~f:(fun arg args ->
        match args with
        | Cmdline.Nil -> Cmdline.Complete arg
        | _ -> Cmdline.Cons (arg, args))
  in
  (Path.root cmd, args, maybe_comp_cword)
;;

let rec add_help_subcommands = function
  | Base  _ as t -> t
  | Exec  _ as t -> t
  | Proxy _ as t -> t
  | Group {summary; readme; subcommands; body} ->
    let subcommands = List.Assoc.map subcommands ~f:add_help_subcommands in
    let subcommands =
      extend_alist_exn subcommands Key_type.Subcommand ~key:"help"
        (help_subcommand ~summary ~readme)
    in
    Group {summary; readme; subcommands; body}
;;

let maybe_apply_extend args ~extend ~path =
  Option.value_map extend ~default:args
    ~f:(fun f -> Cmdline.extend args ~extend:f ~path)
;;

let rec dispatch t env ~extend ~path ~args ~maybe_new_comp_cword ~version ~build_info =
  let to_format_list (group : _ Group.t) : Format.V1.t list =
    let group = Group.to_sexpable ~subcommand_to_sexpable:to_sexpable group in
    List.map group.subcommands ~f:(fun (name, sexpable) ->
      { Format.V1. name; aliases = []; doc = Sexpable.get_summary sexpable })
    |> Format.V1.sort
  in
  match t with
  | Base base ->
    let args = maybe_apply_extend args ~extend ~path in
    Base.run base env ~path ~args
  | Exec exec ->
    Option.iter ~f:set_comp_cword maybe_new_comp_cword;
    let args = Cmdline.to_list (maybe_apply_extend args ~extend ~path) in
    Exec.exec_with_args ~args exec
  | Proxy proxy ->
    Option.iter ~f:set_comp_cword maybe_new_comp_cword;
    let args =
      proxy.path_to_subcommand
      @ Cmdline.to_list (maybe_apply_extend args ~extend ~path)
    in
    let exec =
      { Exec.
        working_dir = proxy.working_dir;
        path_to_exe = proxy.path_to_exe;
        summary = Proxy.get_summary proxy;
        readme = Proxy.get_readme proxy |> Option.map ~f:const;
      }
    in
    Exec.exec_with_args ~args exec
  | Group ({summary; readme; subcommands = subs; body} as group) ->
    let env = Env.set env subs_key subs in
    let die_showing_help msg =
      if not (Cmdline.ends_in_complete args) then begin
        eprintf "%s\n%!"
          (Group.help_text ~to_format_list ~path ~show_flags:false
             {summary; readme; subcommands = subs; body});
        die "%s" msg ()
      end
    in
    match args with
    | Nil ->
      begin
        match body with
        | None -> die_showing_help (sprintf "missing subcommand for command %s" (Path.to_string path))
        | Some body -> body ~path:(Path.commands path)
      end
    | Cons (sub, rest) ->
      let (sub, rest) =
        (* Match for flags recognized when subcommands are expected next *)
        match (sub, rest) with
        (* Recognized at the top level command only *)
        | ("-version", _) when Path.length path = 1 ->
          Version_info.print_version ~version;
          exit 0
        | ("-build-info", _) when Path.length path = 1 ->
          Version_info.print_build_info ~build_info;
          exit 0
        (* Recognized everywhere *)
        | ("-help", Nil) ->
          print_endline
            (Group.help_text ~to_format_list ~path ~show_flags:false
               {group with subcommands = subs});
          exit 0
        | ("-help", Cmdline.Cons (sub, rest)) -> (sub, Cmdline.Cons ("-help", rest))
        | _ -> (sub, rest)
      in
      begin
        match
          lookup_expand (List.Assoc.map subs ~f:(fun x -> (x, `Prefix))) sub Subcommand
        with
        | Error msg -> die_showing_help msg
        | Ok (sub, t) ->
          dispatch t env
            ~extend
            ~path:(Path.add path ~subcommand:sub)
            ~args:rest
            ~maybe_new_comp_cword:(Option.map ~f:Int.pred maybe_new_comp_cword)
            ~version
            ~build_info
      end
    | Complete part ->
      let subs =
        List.map subs ~f:fst
        |> List.filter ~f:(fun name -> String.is_prefix name ~prefix:part)
        |> List.sort ~cmp:String.compare
      in
      List.iter subs ~f:print_endline;
      exit 0
;;

let default_version,default_build_info =
  Version_util.version, Version_util.build_info

let run
      ?(version = default_version)
      ?(build_info = default_build_info)
      ?(argv=Array.to_list Sys.argv)
      ?extend
      t =
  Exn.handle_uncaught ~exit:true (fun () ->
    let t = Version_info.add t ~version ~build_info in
    let t = add_help_subcommands t in
    let (cmd, args) = handle_environment t ~argv in
    let (path, args, maybe_new_comp_cword) = process_args ~cmd ~args in
    try
      dispatch t Env.empty ~extend ~path ~args ~maybe_new_comp_cword
        ~version ~build_info
    with
    | Failed_to_parse_command_line msg ->
      if Cmdline.ends_in_complete args then
        exit 0
      else begin
        prerr_endline msg;
        exit 1
      end)
;;

let summary = function
  | Base  x -> x.summary
  | Group x -> x.summary
  | Exec  x -> x.summary
  | Proxy x -> Proxy.get_summary x

module Spec = struct
  include Base.Spec
  let path = map ~f:Path.commands path
end

module Deprecated = struct

  module Spec = Spec.Deprecated

  let summary = get_summary

  let get_flag_names = function
    | Base base -> base.Base.flags |> String.Map.keys
    | Group _
    | Proxy _
    | Exec  _ -> assert false

  let help_recursive ~cmd ~with_flags ~expand_dots t s =
    let rec help_recursive_rec ~cmd t s =
      let new_s = s ^ (if expand_dots then cmd else ".") ^ " " in
      match t with
      | Base base ->
        let base_help = s ^ cmd, summary (Base base) in
        if with_flags then
          base_help ::
          List.map ~f:(fun (flag, h) -> (new_s ^ flag, h))
            (List.sort ~cmp:Base.Deprecated.subcommand_cmp_fst
               (Base.Deprecated.flags_help ~display_help_flags:false base))
        else
          [base_help]
      | Group {summary; subcommands; readme = _; body = _} ->
        (s ^ cmd, summary)
        :: begin
          subcommands
          |> List.sort ~cmp:Base.Deprecated.subcommand_cmp_fst
          |> List.concat_map ~f:(fun (cmd', t) ->
            help_recursive_rec ~cmd:cmd' t new_s)
        end
      | (Proxy _ | Exec _) ->
        (* Command.exec does not support deprecated commands *)
        []
    in
    help_recursive_rec ~cmd t s

  let version = default_version
  let build_info = default_build_info

  let run t ~cmd ~args ~is_help ~is_help_rec ~is_help_rec_flags ~is_expand_dots =
    let path_strings = String.split cmd ~on: ' ' in
    let path =
      List.fold path_strings ~init:Path.empty ~f:(fun p subcommand ->
        Path.add p ~subcommand)
    in
    let args = if is_expand_dots    then "-expand-dots" :: args else args in
    let args = if is_help_rec_flags then "-flags"       :: args else args in
    let args = if is_help_rec       then "-r"           :: args else args in
    let args = if is_help           then "-help"        :: args else args in
    let args = Cmdline.of_list args in
    let t = add_help_subcommands t in
    dispatch t Env.empty ~path ~args ~extend:None ~maybe_new_comp_cword:None
      ~version ~build_info

end

(* testing claims made in the mli about order of evaluation and [flags_of_args_exn] *)
let%test_module "Command.Spec.flags_of_args_exn" = (module struct

  let args q = [
    ( "flag1", Arg.Unit (fun () -> Queue.enqueue q 1), "enqueue 1");
    ( "flag2", Arg.Unit (fun () -> Queue.enqueue q 2), "enqueue 2");
    ( "flag3", Arg.Unit (fun () -> Queue.enqueue q 3), "enqueue 3");
  ]

  let parse argv =
    let q = Queue.create () in
    let command = basic ~summary:"" (Spec.flags_of_args_exn (args q)) Fn.id in
    run ~argv command;
    Queue.to_list q

  let%test _ = parse ["foo.exe";"-flag1";"-flag2";"-flag3"] = [1;2;3]
  let%test _ = parse ["foo.exe";"-flag2";"-flag3";"-flag1"] = [1;2;3]
  let%test _ = parse ["foo.exe";"-flag3";"-flag2";"-flag1"] = [1;2;3]

end)

(* NOTE: all that follows is simply namespace management boilerplate.  This will go away
   once we re-work the internals of Command to use Applicative from the ground up. *)

module Param = struct
  module type S = sig
    include Applicative.S

    val help : string Lazy.t t
    val path : string list   t
    val args : string list   t

    val flag
      :  ?aliases:string list
      -> ?full_flag_required:unit
      -> string
      -> 'a Flag.t
      -> doc:string
      -> 'a t

    val anon : 'a Anons.t -> 'a t
  end

  module A = struct
    type 'a t = 'a Spec.param
    include Applicative.Make (struct
        type nonrec 'a t = 'a t
        let return = Spec.const
        let apply = Spec.apply
        let map = `Custom Spec.map
      end)
  end

  include A

  let help = Spec.help
  let path = Spec.path
  let args = Spec.args
  let flag = Spec.flag
  let anon = Spec.anon

  module Arg_type = Arg_type
  include Arg_type.Export
  include struct
    open Flag
    let listed                = listed
    let no_arg                = no_arg
    let no_arg_abort          = no_arg_abort
    let no_arg_register       = no_arg_register
    let one_or_more           = one_or_more
    let optional              = optional
    let optional_with_default = optional_with_default
    let required              = required
    let escape                = escape
  end
  include struct
    open Anons
    let (%:)               = (%:)
    let maybe              = maybe
    let maybe_with_default = maybe_with_default
    let non_empty_sequence = non_empty_sequence
    let sequence           = sequence
    let t2                 = t2
    let t3                 = t3
    let t4                 = t4
  end
end

module Let_syntax = struct
  include Param
  module Open_on_rhs = Param
  module Open_in_body = struct end
end

type 'result basic_command'
  =  summary : string
  -> ?readme : (unit -> string)
  -> (unit -> 'result) Param.t
  -> t

let basic' ~summary ?readme param =
  let spec =
    Spec.of_params @@ Param.map param ~f:(fun run () () -> run ())
  in
  basic ~summary ?readme spec ()
