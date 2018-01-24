module Documents
  class CompileCorrections < Action::Base
    attr_accessor :grapheme_ids, :text, :boxes, :branch_name, :revision_id, :document

    validates :grapheme_ids, presence: true
    validates :text, presence: true
    validates :boxes, presence: true
    validate :revision_given

    def execute
      line_diff.specs
    end

    def revision
      @_revision ||= -> {
        if !branch_name.nil?
          rev = Revision.working.where(
            parent_id: document.branches.where(name: branch_name).select("branches.revision_id")
          ).first
          if rev.nil?
            nil
          end
          rev
        else
          Revision.find(revision_id)
        end
      }.call
    end

    def line_diff
      @_line_diff ||= LineDiff.new(grapheme_ids, text, boxes, revision)
    end

    class CorrectionDiff
      def needleman_wunsch(from, to, options = {}, &block)
        Shared::NeedlemanWunsch.run!(
          from: from,
          to: to,
          gap_penalty: options.fetch(:gap_penalty, -1),
          score_fn: block
        ).result
      end

      def levenshtein(first, second)
        if first.length == second.length
          Shared::Levenshtein.run!(
            first: first,
            second: second
          ).result
        else
          second.count
        end
      end

      def graphemes_need_change(from, to)
        value_differs = from.value != to.value
        area_differs = [
          from.area.ulx - to.area.ulx,
          from.area.uly - to.area.uly,
          from.area.lrx - to.area.lrx,
          from.area.lry - to.area.lry
        ].any? { |diff| diff.abs >= 1 }

        value_differs || area_differs
      end
    end

    class LineDiff < CorrectionDiff
      attr_accessor :grapheme_ids, :text, :boxes, :revision

      def initialize(grapheme_ids, text, boxes, revision)
        @grapheme_ids = grapheme_ids
        @text = text
        @boxes = boxes
        @revision = revision
      end

      def specs
        @_specs ||= -> {
          source_list = source_graphemes.dup
          entered_list = entered_graphemes.dup

          all_diffs = word_diffs.map(&:grapheme_diffs).flatten

          diffs = all_diffs.reject(&:deletion?).group_by do |grapheme_diff|
            grapheme_diff.entered.id
          end

          if source_list.first != first_bounding_grapheme
            source_list.insert(0, first_bounding_grapheme)
          end

          if source_list.last != last_bounding_grapheme
            source_list.push(last_bounding_grapheme)
          end

          entered_list.push(last_bounding_grapheme)

          checked_source_idx = 0
          source_idx = 0
          entered_idx = 0
          current_source = nil
          current_entered = nil
          current_span = nil
          diff_spans = [ ]

          while entered_idx < entered_list.count
            if source_idx == source_list.count
              entered_idx += 1
              source_idx = checked_source_idx

              break if entered_idx == entered_list.count
            end

            current_entered = entered_list[ entered_idx ]
            current_source = source_list[ source_idx ]

            if diffs.has_key?( current_entered.id )
              current_span ||= OpenStruct.new({ open: nil, close: nil, diffs: [ ] })
              current_span.open ||= current_source
              current_span.diffs.push( diffs[ current_entered.id ].first )
              entered_idx += 1
              checked_source_idx = source_idx
            else
              if !graphemes_need_change( current_source, current_entered )
                if current_span.present? && current_span.diffs.count > 0
                  current_span.close = current_source
                  diff_spans.push( current_span )
                  current_span = nil
                end
                entered_idx += 1
              else
                source_idx += 1
              end
            end
          end

          if current_span.present?
            current_span.close = last_bounding_grapheme
            diff_spans.push(current_span)
          end

          diff_spans.map do |diff_span|
            grapheme_diffs = diff_span.diffs.sort_by { |diff| diff.entered.position_weight }

            addmod_specs = grapheme_diffs.map(&:to_spec)

            addmod_specs.each_with_index do |addmod_spec, index|
              addmod_spec[:position_weight] = diff_span.open.position_weight +
                ( index + 1 ) * (
                  ( diff_span.close.position_weight - diff_span.open.position_weight ) /
                  ( grapheme_diffs.count + 1.0 )
                )
            end

            addmod_specs
          end.flatten + all_diffs.select(&:deletion?).map(&:to_spec)
        }.call
      end

      def word_diffs
        all_word_diffs.select(&:differ?)
      end

      def all_word_diffs
        @_all_word_diffs ||= -> {
          gap = -> (word) {
            -1 * word.count
          }

          alignments = needleman_wunsch(visually_sorted_source_words, visually_sorted_entered_words,
                                        gap_penalty: gap) do |left, right|
            if left.count != right.count
              -1 * [ left.count, right.count ].max
            elsif left.zip(right).any? { |l, r| graphemes_need_change(l, r) }
              -1 * levenshtein(left.text, right.text)
            else
              left.count
            end
          end

          alignments.first.zip(alignments.last).map do |source, entered|
            WordDiff.new(source, entered, self)
          end
        }.call
      end

      def surface_number
        @_surface_number ||= source_graphemes.first.zone.surface.number
      end

      def source_words
        @_source_words ||= -> {
          initial_state = OpenStruct.new({ result: [], last_lrx: nil })

          source_graphemes_filtered.sort_by { |g| g.area.ulx }.inject(initial_state) do |state, grapheme|
            if state.last_lrx.nil? || grapheme.area.ulx - state.last_lrx > 0
              state.result.push([])
            end

            state.result[ state.result.count - 1 ].push(grapheme)
            state.last_lrx = grapheme.area.lrx

            state
          end.result.map do |graphemes|
            Word.new(graphemes)
          end
        }.call
      end

      def visually_sorted_source_words
        source_words.sort_by { |word| word.area.ulx }
      end

      def entered_words
        @_entered_words ||= -> {
          visually_sorted_words = entered_sorted_visually_text_words_with_indices.sort_by { |w| w[0].visual_index }
          visually_sorted_words.each_with_index.map do |entered_chars, word_index|
            sorted_visually_chars = entered_chars.sort_by { |char| char.visual_index }

            graphemes = sorted_visually_chars.each_with_index.map do |entered_char, local_index|
              box = sorted_boxes[word_index]
              width = box[:lrx] - box[:ulx]
              delta_x = ((width / (1.0 * entered_chars.count)) * local_index)
              delta_x_end = ((width / (1.0 * entered_chars.count)) * (local_index + 1))

              area = Area.new ulx: box[:ulx] + delta_x,
                lrx: box[:ulx] + delta_x_end,
                uly: box[:uly],
                lry: box[:lry]

              Grapheme.new value: entered_char.char,
                area: area,
                zone_id: source_graphemes.first.zone_id,
                position_weight: entered_char.index,
                id: SecureRandom.uuid
            end

            Word.new(graphemes)
          end
        }.call
      end

      def visually_sorted_entered_words
        entered_words.sort_by { |word| word.area.ulx }
      end

      def sorted_boxes
        @_sorted_boxes ||= @boxes.map do |box|
          {
            ulx: box[:ulx].to_f.round,
            uly: box[:uly].to_f.round,
            lrx: box[:lrx].to_f.round,
            lry: box[:lry].to_f.round
          }
        end.sort_by { |box| box[:ulx] }
      end

      def source_graphemes_filtered
        @_source_graphemes_filtered ||= source_graphemes.select do |grapheme|
          codepoint = grapheme.value.codepoints.first
          codepoint != 0x202c && codepoint != 0x200f && codepoint != 0x200e
        end
      end

      def rtl?
        !ltr?
      end

      def ltr?
        @_ltr ||= first_bounding_grapheme.value.codepoints.first === 0x200e
      end

      def source_graphemes
        @_source_graphemes ||= Grapheme.where(id: @grapheme_ids).to_a
      end

      def entered_graphemes
        @_entered_graphemes ||= entered_words.map do |entered_word|
          entered_word.graphemes
        end.flatten.sort_by { |g| g.position_weight }
      end

      def entered_sorted_visually_text_words_with_indices
        @_entered_sorted_visually_text_words_with_indices ||= -> {
          visual_indices = Bidi.to_visual_indices(normalized_entered_text, rtl? ? :rtl : :ltr)

          visual_indices.each_with_index.map do |index, visual_index|
            EnteredChar.new(normalized_entered_text[index], index, visual_index)
          end.inject([[]]) do |state, entered_char|
            if entered_char.char[/\s+/].nil?
              state[ state.count - 1].push(entered_char)
            else
              state.push([ ])
            end

            state
          end.reject(&:empty?)
        }.call
      end

      def normalized_entered_text
        @_normalized_entered_text ||= -> {
          @text.codepoints.select do |codepoint|
            codepoint != 0x200e && codepoint != 0x200f && codepoint != 0x202c
          end.pack("U*").strip
        }.call
      end

      def grapheme_special?(grapheme)
        codepoint = grapheme.value.codepoints.first

        codepoint == 0x200e || codepoint == 0x200f || codepoint == 0x202c
      end

      def match_source_by_entered(entered_grapheme)
        source_graphemes.find do |source_grapheme|
          !graphemes_need_change(source_grapheme, entered_grapheme)
        end
      end

      def first_bounding_grapheme
        @_first_bounding_grapheme || -> {
          if grapheme_special?(source_graphemes.first)
            source_graphemes.first
          else
            revision.graphemes.
              where("position_weight < ?", source_graphemes.first.position_weight).
              reorder("position_weight desc").
              first
          end
        }.call
      end

      def last_bounding_grapheme
        @_last_bounding_grapheme || -> {
          if grapheme_special?(source_graphemes.last)
            source_graphemes.last
          else
            revision.graphemes.
              where("position_weight > ?", source_graphemes.last.position_weight).
              reorder("position_weight asc").
              first
          end
        }.call
      end

      class EnteredChar
        attr_accessor :char, :index, :visual_index

        def initialize(char, index, visual_index)
          @char = char
          @index = index
          @visual_index = visual_index
        end
      end
    end

    class WordDiff < CorrectionDiff
      attr_accessor :source, :entered, :line_diff

      def initialize(source, entered, line_diff)
        @source = source
        @entered = entered
        @line_diff = line_diff
      end

      def grapheme_diffs
        @_grapheme_diffs ||= -> {
          source_alignment, entered_alignment = needleman_wunsch(source, entered,
                                                                 gap_penalty: -1) do |left, right|
            graphemes_need_change(left, right) ? -1 : 1
          end

          source_alignment.zip(entered_alignment).map do |from, to|
            GraphemeDiff.new(from, to, self)
          end.select(&:differ?)
        }.call
      end

      def differ?
        source.nil? && entered.present? ||
          source.present? && entered.nil? ||
          source != entered
      end

      def inspect
        "<WordDiff source: #{ @source.inspect } entered: #{ @entered.inspect }>"
      end
    end

    class GraphemeDiff < CorrectionDiff
      attr_accessor :source, :entered, :word_diff

      def initialize(source, entered, word_diff)
        @source = source
        @entered = entered
        @word_diff = word_diff
      end

      def to_spec
        if addition?
          {
            value: entered.value,
            area: entered.area,
            surface_number: word_diff.line_diff.surface_number,
            position_weight: nil
          }
        elsif deletion?
          {
            id: source.id,
            delete: true
          }
        elsif modification?
          {
            id: source.id,
            position_weight: nil,
            value: entered.value,
            area: entered.area,
            surface_number: word_diff.line_diff.surface_number
          }
        else
          raise StandardError, "No change spec for diff pointing at equal graphemes"
        end
      end

      def inspect_grapheme(g)
        g.nil? ? "<nil>" : "| #{ g.value } @: #{ g.area } #: #{ g.position_weight } |"
      end

      def inspect
        "<GraphemeDiff source: #{ inspect_grapheme(source) } || entered: #{ inspect_grapheme(entered) } >"
      end

      def differ?
        addition? || deletion? || modification?
      end

      def addition?
        source.nil? && entered.present?
      end

      def deletion?
        source.present? && entered.nil?
      end

      def modification?
        source.present? && entered.present? &&
          ( source.value != entered.value || source.area != entered.area )
      end
    end

    class Word
      include Enumerable

      attr_accessor :graphemes

      def initialize(graphemes)
        @graphemes = graphemes
      end

      def [](index)
        logically_ordered[index]
      end

      def each(&block)
        logically_ordered.each(&block)
      end

      def count
        @graphemes.count
      end

      def logically_ordered
        @_logically_ordered ||= @graphemes.sort_by(&:position_weight)
      end

      def visually_ordered
        @_visually_ordered ||= @graphemes.sort_by { |g| g.area.ulx }
      end

      def text
        logically_ordered.map(&:value).join('')
      end

      def has_new?
        logically_ordered.any? { |g| !g.persisted? }
      end

      def ==(other)
        other.nil? || (
          text == other.text &&
          area == other.area
        )
      end

      def area
        @_area ||= Area.new(
          ulx: visually_ordered.first.area.ulx,
          uly: visually_ordered.first.area.uly,
          lrx: visually_ordered.last.area.lrx,
          lry: visually_ordered.last.area.lry
        )
      end

      def inspect
        "<Word #{ has_new? ? '=N=' : '' } text: \"#{ text }\" area: #{ area }>"
      end
    end

    def create_development_dumps?
      true
    end

    def revision_given
      if revision.nil?
        errors.add(:base, "Given branch name or revision id doesn't point at any existing revision")
      end
    end
  end
end
