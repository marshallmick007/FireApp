# -*- coding: utf-8 -*-
#
#--
# Copyright (C) 2009-2012 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown.
#
# kramdown is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++
#

require 'kramdown/parser/kramdown/blank_line'
require 'kramdown/parser/kramdown/eob'
require 'kramdown/parser/kramdown/horizontal_rule'
require 'kramdown/parser/kramdown/extensions'

module Kramdown
  module Parser
    class Kramdown

      LIST_ITEM_IAL = /^\s*(?:\{:(?!(?:#{ALD_ID_NAME})?:|\/)(#{ALD_ANY_CHARS}+)\})\s*/
      LIST_ITEM_IAL_CHECK = /^#{LIST_ITEM_IAL}?\s*\n/

      # Used for parsing the first line of a list item or a definition, i.e. the line with list item
      # marker or the definition marker.
      def parse_first_list_line(indentation, content)
        if content =~ self.class::LIST_ITEM_IAL_CHECK
          indentation = 4
        else
          while content =~ /^ *\t/
            temp = content.scan(/^ */).first.length + indentation
            content.sub!(/^( *)(\t+)/) {$1 << " "*(4 - (temp % 4) + ($2.length - 1)*4)}
          end
          indentation += content.scan(/^ */).first.length
        end
        content.sub!(/^\s*/, '')

        indent_re = /^ {#{indentation}}/
        content_re = /^(?:(?:\t| {4}){#{indentation / 4}} {#{indentation % 4}}|(?:\t| {4}){#{indentation / 4 + 1}}).*\S.*\n/
        lazy_re = /(?!^ {0,#{[indentation, 3].min}}(?:#{IAL_BLOCK}|#{LAZY_END_HTML_STOP}|#{LAZY_END_HTML_START})).*\S.*\n/
        [content, indentation, content_re, lazy_re, indent_re]
      end


      LIST_START_UL = /^(#{OPT_SPACE}[+*-])([\t| ].*?\n)/
      LIST_START_OL = /^(#{OPT_SPACE}\d+\.)([\t| ].*?\n)/
      LIST_START = /#{LIST_START_UL}|#{LIST_START_OL}/

      # Parse the ordered or unordered list at the current location.
      def parse_list
        type, list_start_re = (@src.check(LIST_START_UL) ? [:ul, LIST_START_UL] : [:ol, LIST_START_OL])
        list = new_block_el(type)

        item = nil
        content_re, lazy_re, indent_re = nil
        eob_found = false
        nested_list_found = false
        last_is_blank = false
        while !@src.eos?
          if last_is_blank && @src.check(HR_START)
            break
          elsif @src.scan(EOB_MARKER)
            eob_found = true
            break
          elsif @src.scan(list_start_re)
            item = Element.new(:li)
            item.value, indentation, content_re, lazy_re, indent_re = parse_first_list_line(@src[1].length, @src[2])
            list.children << item

            item.value.sub!(self.class::LIST_ITEM_IAL) do |match|
              parse_attribute_list($1, item.options[:ial] ||= {})
              ''
            end

            list_start_re = (type == :ul ? /^( {0,#{[3, indentation - 1].min}}[+*-])([\t| ].*?\n)/ :
                             /^( {0,#{[3, indentation - 1].min}}\d+\.)([\t| ].*?\n)/)
            nested_list_found = (item.value =~ LIST_START)
            last_is_blank = false
          elsif (result = @src.scan(content_re)) || (!last_is_blank && (result = @src.scan(lazy_re)))
            result.sub!(/^(\t+)/) { " "*($1 ? 4*$1.length : 0) }
            result.sub!(indent_re, '')
            if !nested_list_found && result =~ LIST_START
              item.value << "^\n"
              nested_list_found = true
            end
            item.value << result
            last_is_blank = false
          elsif result = @src.scan(BLANK_LINE)
            nested_list_found = true
            last_is_blank = true
            item.value << result
          else
            break
          end
        end

        @tree.children << list

        last = nil
        list.children.each do |it|
          temp = Element.new(:temp)
          parse_blocks(temp, it.value)
          it.children = temp.children
          it.value = nil
          next if it.children.size == 0

          # Handle the case where an EOB marker is inserted by a block IAL for the first paragraph
          it.children.delete_at(1) if it.children.first.type == :p &&
            it.children.length >= 2 && it.children[1].type == :eob && it.children.first.options[:ial]

          if it.children.first.type == :p &&
              (it.children.length < 2 || it.children[1].type != :blank ||
               (it == list.children.last && it.children.length == 2 && !eob_found)) &&
              (list.children.last != it || list.children.size == 1 ||
               list.children[0..-2].any? {|cit| !cit.children.first || cit.children.first.type != :p || cit.children.first.options[:transparent]})
            it.children.first.children.first.value << "\n" if it.children.size > 1 && it.children[1].type != :blank
            it.children.first.options[:transparent] = true
          end

          if it.children.last.type == :blank
            last = it.children.pop
          else
            last = nil
          end
        end

        @tree.children << last if !last.nil? && !eob_found

        true
      end
      define_parser(:list, LIST_START)


      DEFINITION_LIST_START = /^(#{OPT_SPACE}:)([\t| ].*?\n)/

      # Parse the ordered or unordered list at the current location.
      def parse_definition_list
        children = @tree.children
        if !children.last || (children.length == 1 && children.last.type != :p ) ||
            (children.length >= 2 && children[-1].type != :p && (children[-1].type != :blank || children[-1].value != "\n" || children[-2].type != :p))
          return false
        end

        first_as_para = false
        deflist = new_block_el(:dl)
        para = @tree.children.pop
        if para.type == :blank
          para = @tree.children.pop
          first_as_para = true
        end
        para.children.first.value.split(/\n/).each do |term|
          el = Element.new(:dt)
          el.children << Element.new(:raw_text, term)
          deflist.children << el
        end

        item = nil
        content_re, lazy_re, indent_re = nil
        def_start_re = DEFINITION_LIST_START
        last_is_blank = false
        while !@src.eos?
          if @src.scan(def_start_re)
            item = Element.new(:dd)
            item.options[:first_as_para] = first_as_para
            item.value, indentation, content_re, lazy_re, indent_re = parse_first_list_line(@src[1].length, @src[2])
            deflist.children << item

            item.value.sub!(self.class::LIST_ITEM_IAL) do |match|
              parse_attribute_list($1, item.options[:ial] ||= {})
              ''
            end

            def_start_re = /^( {0,#{[3, indentation - 1].min}}:)([\t| ].*?\n)/
            first_as_para = false
            last_is_blank = false
          elsif @src.check(EOB_MARKER)
            break
          elsif (result = @src.scan(content_re)) || (!last_is_blank && (result = @src.scan(lazy_re)))
            result.sub!(/^(\t+)/) { " "*($1 ? 4*$1.length : 0) }
            result.sub!(indent_re, '')
            item.value << result
            first_as_para = false
            last_is_blank = false
          elsif result = @src.scan(BLANK_LINE)
            first_as_para = true
            item.value << result
            last_is_blank = true
          else
            break
          end
        end

        last = nil
        deflist.children.each do |it|
          next if it.type == :dt

          parse_blocks(it, it.value)
          it.value = nil
          next if it.children.size == 0

          if it.children.last.type == :blank
            last = it.children.pop
          else
            last = nil
          end
          if it.children.first.type == :p && !it.options.delete(:first_as_para)
            it.children.first.children.first.value << "\n" if it.children.size > 1
            it.children.first.options[:transparent] = true
          end
        end

        if @tree.children.length >= 1 && @tree.children.last.type == :dl
          @tree.children[-1].children.concat(deflist.children)
        elsif @tree.children.length >= 2 && @tree.children[-1].type == :blank && @tree.children[-2].type == :dl
          @tree.children.pop
          @tree.children[-1].children.concat(deflist.children)
        else
          @tree.children << deflist
        end

        @tree.children << last if !last.nil?

        true
      end
      define_parser(:definition_list, DEFINITION_LIST_START)

    end
  end
end
