class Grapheme < ApplicationRecord
  belongs_to :zone
  has_and_belongs_to_many :revisions

  serialize :area, Area::Serializer

  default_scope { order("(graphemes.area[0])[1] asc, (graphemes.area[0])[0] asc") }

  def self.diff(revision1, revision2)
    side_query = -> (side) {
      rev1, rev2 = side == 'left' ? [ revision1, revision2 ] : [ revision2, revision1 ]

      Grapheme.where(id: rev1.graphemes).
              where.not(id: rev2.graphemes).
              select("graphemes.*, '#{side}' as inclusion")
    }

    side_query.call('left').
      union_all(
        side_query.call('right')
      )
  end

  class Tree < Grape::Entity
    expose :area, with: Area::Tree
    expose :value
    expose :id
    expose :certainty
  end
end
