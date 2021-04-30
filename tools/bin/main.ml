open Core

(* constants *)

let chapters_list = "book/chapters.json"

let chapters_dir = "book/chapters/"

let chapter_template = "templates/chapter.html"

let index_template = "templates/index.html"

let output_dir = "dist/"

(* data structures *)

type explanation =
  | Parsed of { code : string list; explanation : string }
  | Unparsed of { line : int; text : string }
[@@deriving show]

type section = { file : string; lang : string; explanations : explanation list }
[@@deriving show]

type chapter = { title : string; folder : string; sections : section list }
[@@deriving show]

(* read *)

let get_chapter folder =
  let chapter_file = chapters_dir ^ folder ^ "/" ^ "chapter.json" in
  let json = Yojson.Basic.from_file chapter_file in
  let open Yojson.Basic.Util in
  let title = json |> member "title" |> to_string in
  let to_explanation = function
    | `Assoc [ ("line", line); ("text", text) ] ->
        Unparsed { line = to_int line; text = to_string text }
    | _ ->
        failwith
          "misformated chapter.json: explanations must contain blocks of { \
           line, text }"
  in
  let to_section = function
    | `Assoc [ ("file", file); ("lang", lang); ("explanations", explanations) ]
      ->
        let file = to_string file in
        let lang = to_string lang in
        let explanations = explanations |> convert_each to_explanation in
        { file; lang; explanations }
    | _ ->
        failwith
          "misformated chapter.json: sections must contain blocks of { file, \
           explanations }"
  in
  let sections = json |> member "sections" |> convert_each to_section in
  { title; folder; sections }

let get_chapters _ =
  let json = Yojson.Basic.from_file chapters_list in
  let open Yojson.Basic.Util in
  let chapters = json |> member "chapters" |> to_list |> filter_string in
  let chapters = List.map chapters ~f:get_chapter in
  chapters

let get_code folder file_name =
  let file_name = chapters_dir ^ folder ^ "/" ^ file_name in
  In_channel.read_lines file_name

(* transform *)

let produce_explanation (code : string list) (ln : int) (e : explanation)
    (rest_expls : explanation list) =
  match e with
  | Unparsed expl ->
      (* explanation starts later *)
      if ln < expl.line then
        let limit = expl.line - ln in
        let code, remaining_code = List.split_n code limit in
        let explanation = Parsed { code; explanation = "" } in
        let ln = expl.line in
        (explanation, ln, remaining_code, e :: rest_expls)
        (* explanation starts now *)
      else if ln = expl.line then
        match rest_expls with
        (* explanation goes to the end *)
        | [] ->
            let explanation = Parsed { code; explanation = expl.text } in
            let ln = ln + List.length code in
            let remaining_code = [] in
            (explanation, ln, remaining_code, [])
        (* explanation is upper bounded *)
        | Unparsed next :: rest_expls ->
            let limit = next.line - ln in
            let code, remaining_code = List.split_n code limit in
            let explanation = Parsed { code; explanation = expl.text } in
            let ln = next.line in
            let rest_expls = Unparsed next :: rest_expls in
            (explanation, ln, remaining_code, rest_expls)
        | _ ->
            failwith
              "this shouldn't happen, parsed explanation should be unparsed"
      else failwith "this shouldn't happen, byexample missed an explanation"
  | _ -> failwith "this shouldn't happen, explanation passed is parsed"

let rec produce_explanations (result : explanation list) ln (code : string list)
    (explanations : explanation list) =
  match (code, explanations) with
  | [], [] -> result
  | code, [] -> result @ [ Parsed { code; explanation = "" } ]
  | [], [ Unparsed expl ] when expl.line > ln ->
      result @ [ Parsed { code = []; explanation = expl.text } ]
  | [], Unparsed expl :: _ ->
      eprintf "explanation dangling: %s" expl.text;
      failwith
        "misformated chapter.json: there can only be one trailing explanation \
         (with no associated code)"
  | [], _ ->
      failwith
        "this shouldn't happen, trailing explanation has already been parsed"
  | code, expl :: rest_expls ->
      let explanation, ln, remaining_code, rest_expls =
        produce_explanation code ln expl rest_expls
      in
      let new_result = result @ [ explanation ] in
      produce_explanations new_result ln remaining_code rest_expls

let parse_section folder ({ file; explanations; _ } as section) =
  let code = get_code folder file in
  let explanations = produce_explanations [] 1 code explanations in
  { section with explanations }

let parse_chapter ({ folder; sections; _ } as chapter) =
  let sections = List.map sections ~f:(parse_section folder) in
  { chapter with sections }

let parse_chapters chapters = List.map chapters ~f:parse_chapter

(* write *)

let explanation_to_model = function
  | Unparsed _ ->
      failwith "this shouldn't happen, explanations must be parsed first"
  | Parsed { code; explanation } ->
      let code = String.concat code ~sep:"\n" in
      let open Jingoo.Jg_types in
      Tobj [ ("code", Tstr code); ("explanation", Tstr explanation) ]

let section_to_model { file; lang; explanations } =
  let explanations = List.map explanations ~f:explanation_to_model in
  let open Jingoo.Jg_types in
  Tobj
    [
      ("file", Tstr file);
      ("lang", Tstr lang);
      ("explanations", Tlist explanations);
    ]

let chapter_to_html { title; folder; sections } =
  let sections = List.map sections ~f:section_to_model in
  let open Jingoo in
  let models =
    [
      ("title", Jg_types.Tstr title);
      ("folder", Jg_types.Tstr folder);
      ("sections", Jg_types.Tlist sections);
    ]
  in
  let result = Jg_template.from_file chapter_template ~models in
  (folder, result)

let chapters_to_index chapters =
  let open Jingoo in
  let chapter_to_model chapter =
    Jg_types.Tobj
      [
        ("title", Jg_types.Tstr chapter.title);
        ("folder", Jg_types.Tstr chapter.folder);
      ]
  in
  let chapters = List.map chapters ~f:chapter_to_model in
  let models = [ ("chapters", Jg_types.Tlist chapters) ] in
  let result = Jg_template.from_file index_template ~models in
  result

let html_to_disk (name, data) =
  let output_file = output_dir ^ name ^ ".html" in
  Out_channel.write_all output_file ~data

let chapters_to_html chapters =
  let chapters_html = List.map chapters ~f:chapter_to_html in
  List.iter chapters_html ~f:html_to_disk

let index_to_html chapters =
  let index_html = chapters_to_index chapters in
  html_to_disk ("index", index_html)

(* helpers *)

let print_explanation = function
  | Unparsed { line; text } -> printf "    + %d: %s\n" line text
  | Parsed { code; explanation } ->
      let code = String.concat ~sep:"\n" code in
      printf "    + code: %s\n    + %s\n" code explanation

let print_section { file; lang; explanations } =
  printf "  - %s (%s)\n" file lang;
  List.iter explanations ~f:print_explanation

let print_chapter (idx : int) { title; sections; _ } =
  printf "%d - %s\n" (idx + 1) title;
  List.iter sections ~f:print_section

(* main *)

let main _ =
  Unix.mkdir_p output_dir;
  let chapters = parse_chapters @@ get_chapters @@ () in
  chapters_to_html chapters;
  index_to_html chapters;
  printf "done generating HTML files in dist/\n"

let () = main ()