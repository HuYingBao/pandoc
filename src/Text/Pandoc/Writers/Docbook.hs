{-# LANGUAGE OverloadedStrings, PatternGuards #-}
{-
Copyright (C) 2006-2015 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.Docbook
   Copyright   : Copyright (C) 2006-2015 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to Docbook XML.
-}
module Text.Pandoc.Writers.Docbook ( writeDocbook) where
import Text.Pandoc.Definition
import Text.Pandoc.XML
import Text.Pandoc.Shared
import Text.Pandoc.Walk
import Text.Pandoc.Writers.Shared
import Text.Pandoc.Options
import Text.Pandoc.Templates (renderTemplate')
import Text.Pandoc.Writers.Math
import Data.List ( stripPrefix, isPrefixOf, intercalate, isSuffixOf )
import Data.Char ( toLower )
import Data.Monoid ( Any(..) )
import Text.Pandoc.Highlighting ( languages, languagesByExtension )
import Text.Pandoc.Pretty
import Text.Pandoc.ImageSize
import qualified Text.Pandoc.Builder as B
import Text.TeXMath
import qualified Text.XML.Light as Xml
import Data.Generics (everywhere, mkT)
import Text.Pandoc.Class (PandocMonad)

-- | Convert list of authors to a docbook <author> section
authorToDocbook :: PandocMonad m => WriterOptions -> [Inline] -> m B.Inlines
authorToDocbook opts name' = do
  name <- render Nothing <$> inlinesToDocbook opts name'
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  return $ B.rawInline "docbook" $ render colwidth $
      if ',' `elem` name
         then -- last name first
              let (lastname, rest) = break (==',') name
                  firstname = triml rest in
              inTagsSimple "firstname" (text $ escapeStringForXML firstname) <>
              inTagsSimple "surname" (text $ escapeStringForXML lastname)
         else -- last name last
              let namewords = words name
                  lengthname = length namewords
                  (firstname, lastname) = case lengthname of
                    0  -> ("","")
                    1  -> ("", name)
                    n  -> (intercalate " " (take (n-1) namewords), last namewords)
               in inTagsSimple "firstname" (text $ escapeStringForXML firstname) $$
                  inTagsSimple "surname" (text $ escapeStringForXML lastname)

-- | Convert Pandoc document to string in Docbook format.
writeDocbook :: PandocMonad m => WriterOptions -> Pandoc -> m String
writeDocbook opts (Pandoc meta blocks) = do
  let elements = hierarchicalize blocks
  let colwidth = if writerWrapText opts == WrapAuto
                    then Just $ writerColumns opts
                    else Nothing
  let render'  = render colwidth
  let opts'    = if (maybe False (("/book>" `isSuffixOf`) . trimr)
                            (writerTemplate opts) &&
                     TopLevelDefault == writerTopLevelDivision opts)
                    then opts{ writerTopLevelDivision = TopLevelChapter }
                    else opts
  -- The numbering here follows LaTeX's internal numbering
  let startLvl = case writerTopLevelDivision opts' of
                   TopLevelPart    -> -1
                   TopLevelChapter -> 0
                   TopLevelSection -> 1
                   TopLevelDefault -> 1
  auths' <- mapM (authorToDocbook opts) $ docAuthors meta
  let meta' = B.setMeta "author" auths' meta
  metadata <- metaToJSON opts
                 (fmap (render colwidth . vcat) .
                          (mapM (elementToDocbook opts' startLvl) .
                            hierarchicalize))
                 (fmap (render colwidth) . inlinesToDocbook opts')
                 meta'
  main <- (render' . vcat) <$> mapM (elementToDocbook opts' startLvl) elements
  let context = defField "body" main
              $ defField "mathml" (case writerHTMLMathMethod opts of
                                        MathML _ -> True
                                        _        -> False)
              $ metadata
  return $ case writerTemplate opts of
           Nothing   -> main
           Just tpl  -> renderTemplate' tpl context

-- | Convert an Element to Docbook.
elementToDocbook :: PandocMonad m => WriterOptions -> Int -> Element -> m Doc
elementToDocbook opts _   (Blk block) = blockToDocbook opts block
elementToDocbook opts lvl (Sec _ _num (id',_,_) title elements) = do
  -- Docbook doesn't allow sections with no content, so insert some if needed
  let elements' = if null elements
                    then [Blk (Para [])]
                    else elements
      tag = case lvl of
                 -1                   -> "part"
                 0                    -> "chapter"
                 n | n >= 1 && n <= 5 -> if writerDocbook5 opts
                                              then "section"
                                              else "sect" ++ show n
                 _                    -> "simplesect"
      idName = if writerDocbook5 opts
                 then "xml:id"
                 else "id"
      idAttr = [(idName, writerIdentifierPrefix opts ++ id') | not (null id')]
      nsAttr = if writerDocbook5 opts && lvl == 0 then [("xmlns", "http://docbook.org/ns/docbook"),("xmlns:xlink", "http://www.w3.org/1999/xlink")]
                                      else []
      attribs = nsAttr ++ idAttr
  contents <- mapM (elementToDocbook opts (lvl + 1)) elements'
  title' <- inlinesToDocbook opts title
  return $ inTags True tag attribs $
      inTagsSimple "title" title' $$ vcat contents

-- | Convert a list of Pandoc blocks to Docbook.
blocksToDocbook :: PandocMonad m => WriterOptions -> [Block] -> m Doc
blocksToDocbook opts = fmap vcat . mapM (blockToDocbook opts)

-- | Auxiliary function to convert Plain block to Para.
plainToPara :: Block -> Block
plainToPara (Plain x) = Para x
plainToPara x         = x

-- | Convert a list of pairs of terms and definitions into a list of
-- Docbook varlistentrys.
deflistItemsToDocbook :: PandocMonad m
                      => WriterOptions -> [([Inline],[[Block]])] -> m Doc
deflistItemsToDocbook opts items =
  vcat <$> mapM (\(term, defs) -> deflistItemToDocbook opts term defs) items

-- | Convert a term and a list of blocks into a Docbook varlistentry.
deflistItemToDocbook :: PandocMonad m
                     => WriterOptions -> [Inline] -> [[Block]] -> m Doc
deflistItemToDocbook opts term defs = do
  term' <- inlinesToDocbook opts term
  def' <- blocksToDocbook opts $ concatMap (map plainToPara) defs
  return $ inTagsIndented "varlistentry" $
      inTagsIndented "term" term' $$
      inTagsIndented "listitem" def'

-- | Convert a list of lists of blocks to a list of Docbook list items.
listItemsToDocbook :: PandocMonad m => WriterOptions -> [[Block]] -> m Doc
listItemsToDocbook opts items = vcat <$> mapM (listItemToDocbook opts) items

-- | Convert a list of blocks into a Docbook list item.
listItemToDocbook :: PandocMonad m => WriterOptions -> [Block] -> m Doc
listItemToDocbook opts item =
  inTagsIndented "listitem" <$> blocksToDocbook opts (map plainToPara item)

imageToDocbook :: WriterOptions -> Attr -> String -> Doc
imageToDocbook _ attr src = selfClosingTag "imagedata" $
  ("fileref", src) : idAndRole attr ++ dims
  where
    dims = go Width "width" ++ go Height "depth"
    go dir dstr = case (dimension dir attr) of
                    Just a  -> [(dstr, show a)]
                    Nothing -> []

-- | Convert a Pandoc block element to Docbook.
blockToDocbook :: PandocMonad m => WriterOptions -> Block -> m Doc
blockToDocbook _ Null = return empty
-- Add ids to paragraphs in divs with ids - this is needed for
-- pandoc-citeproc to get link anchors in bibliographies:
blockToDocbook opts (Div (ident,_,_) [Para lst]) =
  let attribs = [("id", ident) | not (null ident)] in
  if hasLineBreaks lst
     then (flush . nowrap . inTags False "literallayout" attribs)
                         <$> inlinesToDocbook opts lst
     else inTags True "para" attribs <$> inlinesToDocbook opts lst
blockToDocbook opts (Div (ident,_,_) bs) = do
  contents <- blocksToDocbook opts (map plainToPara bs)
  return $
    (if null ident
        then mempty
        else selfClosingTag "anchor" [("id", ident)]) $$ contents
blockToDocbook _ (Header _ _ _) =
  return empty -- should not occur after hierarchicalize
blockToDocbook opts (Plain lst) = inlinesToDocbook opts lst
-- title beginning with fig: indicates that the image is a figure
blockToDocbook opts (Para [Image attr txt (src,'f':'i':'g':':':_)]) = do
  alt <- inlinesToDocbook opts txt
  let capt = if null txt
                then empty
                else inTagsSimple "title" alt
  return $ inTagsIndented "figure" $
        capt $$
        (inTagsIndented "mediaobject" $
           (inTagsIndented "imageobject"
             (imageToDocbook opts attr src)) $$
           inTagsSimple "textobject" (inTagsSimple "phrase" alt))
blockToDocbook opts (Para lst)
  | hasLineBreaks lst = (flush . nowrap . inTagsSimple "literallayout")
                        <$> inlinesToDocbook opts lst
  | otherwise         = inTagsIndented "para" <$> inlinesToDocbook opts lst
blockToDocbook opts (LineBlock lns) =
  blockToDocbook opts $ linesToPara lns
blockToDocbook opts (BlockQuote blocks) =
  inTagsIndented "blockquote" <$> blocksToDocbook opts blocks
blockToDocbook _ (CodeBlock (_,classes,_) str) = return $
  text ("<programlisting" ++ lang ++ ">") <> cr <>
     flush (text (escapeStringForXML str) <> cr <> text "</programlisting>")
    where lang  = if null langs
                     then ""
                     else " language=\"" ++ escapeStringForXML (head langs) ++
                          "\""
          isLang l    = map toLower l `elem` map (map toLower) languages
          langsFrom s = if isLang s
                           then [s]
                           else languagesByExtension . map toLower $ s
          langs       = concatMap langsFrom classes
blockToDocbook opts (BulletList lst) = do
  let attribs = [("spacing", "compact") | isTightList lst]
  inTags True "itemizedlist" attribs <$> listItemsToDocbook opts lst
blockToDocbook _ (OrderedList _ []) = return empty
blockToDocbook opts (OrderedList (start, numstyle, _) (first:rest)) = do
  let numeration = case numstyle of
                       DefaultStyle -> []
                       Decimal      -> [("numeration", "arabic")]
                       Example      -> [("numeration", "arabic")]
                       UpperAlpha   -> [("numeration", "upperalpha")]
                       LowerAlpha   -> [("numeration", "loweralpha")]
                       UpperRoman   -> [("numeration", "upperroman")]
                       LowerRoman   -> [("numeration", "lowerroman")]
      spacing    = [("spacing", "compact") | isTightList (first:rest)]
      attribs    = numeration ++ spacing
  items <- if start == 1
              then listItemsToDocbook opts (first:rest)
              else do
                first' <- blocksToDocbook opts (map plainToPara first)
                rest' <- listItemsToDocbook opts rest
                return $
                  (inTags True "listitem" [("override",show start)] first') $$
                   rest'
  return $ inTags True "orderedlist" attribs items
blockToDocbook opts (DefinitionList lst) = do
  let attribs = [("spacing", "compact") | isTightList $ concatMap snd lst]
  inTags True "variablelist" attribs <$> deflistItemsToDocbook opts lst
blockToDocbook opts (RawBlock f str)
  | f == "docbook" = return $ text str -- raw XML block
  | f == "html"    = if writerDocbook5 opts
                        then return empty -- No html in Docbook5
                        else return $ text str -- allow html for backwards compatibility
  | otherwise      = return empty
blockToDocbook _ HorizontalRule = return empty -- not semantic
blockToDocbook opts (Table caption aligns widths headers rows) = do
  captionDoc <- if null caption
                   then return empty
                   else inTagsIndented "title" <$>
                         inlinesToDocbook opts caption
  let tableType    = if isEmpty captionDoc then "informaltable" else "table"
      percent w    = show (truncate (100*w) :: Integer) ++ "*"
      coltags = vcat $ zipWith (\w al -> selfClosingTag "colspec"
                       ([("colwidth", percent w) | w > 0] ++
                        [("align", alignmentToString al)])) widths aligns
  head' <- if all null headers
              then return empty
              else inTagsIndented "thead" <$> tableRowToDocbook opts headers
  body' <- (inTagsIndented "tbody" . vcat) <$>
              mapM (tableRowToDocbook opts) rows
  return $ inTagsIndented tableType $ captionDoc $$
        (inTags True "tgroup" [("cols", show (length headers))] $
         coltags $$ head' $$ body')

hasLineBreaks :: [Inline] -> Bool
hasLineBreaks = getAny . query isLineBreak . walk removeNote
  where
    removeNote :: Inline -> Inline
    removeNote (Note _) = Str ""
    removeNote x = x
    isLineBreak :: Inline -> Any
    isLineBreak LineBreak = Any True
    isLineBreak _ = Any False

alignmentToString :: Alignment -> [Char]
alignmentToString alignment = case alignment of
                                 AlignLeft -> "left"
                                 AlignRight -> "right"
                                 AlignCenter -> "center"
                                 AlignDefault -> "left"

tableRowToDocbook :: PandocMonad m
                  => WriterOptions
                  -> [[Block]]
                  -> m Doc
tableRowToDocbook opts cols =
  (inTagsIndented "row" . vcat) <$> mapM (tableItemToDocbook opts) cols

tableItemToDocbook :: PandocMonad m
                   => WriterOptions
                   -> [Block]
                   -> m Doc
tableItemToDocbook opts item =
  (inTags True "entry" [] . vcat) <$> mapM (blockToDocbook opts) item

-- | Convert a list of inline elements to Docbook.
inlinesToDocbook :: PandocMonad m => WriterOptions -> [Inline] -> m Doc
inlinesToDocbook opts lst = hcat <$> mapM (inlineToDocbook opts) lst

-- | Convert an inline element to Docbook.
inlineToDocbook :: PandocMonad m => WriterOptions -> Inline -> m Doc
inlineToDocbook _ (Str str) = return $ text $ escapeStringForXML str
inlineToDocbook opts (Emph lst) =
  inTagsSimple "emphasis" <$> inlinesToDocbook opts lst
inlineToDocbook opts (Strong lst) =
  inTags False "emphasis" [("role", "strong")] <$> inlinesToDocbook opts lst
inlineToDocbook opts (Strikeout lst) =
  inTags False "emphasis" [("role", "strikethrough")] <$>
  inlinesToDocbook opts lst
inlineToDocbook opts (Superscript lst) =
  inTagsSimple "superscript" <$> inlinesToDocbook opts lst
inlineToDocbook opts (Subscript lst) =
  inTagsSimple "subscript" <$> inlinesToDocbook opts lst
inlineToDocbook opts (SmallCaps lst) =
  inTags False "emphasis" [("role", "smallcaps")] <$>
  inlinesToDocbook opts lst
inlineToDocbook opts (Quoted _ lst) =
  inTagsSimple "quote" <$> inlinesToDocbook opts lst
inlineToDocbook opts (Cite _ lst) =
  inlinesToDocbook opts lst
inlineToDocbook opts (Span (ident,_,_) ils) =
  ((if null ident
       then mempty
       else selfClosingTag "anchor" [("id", ident)]) <>) <$>
  inlinesToDocbook opts ils
inlineToDocbook _ (Code _ str) =
  return $ inTagsSimple "literal" $ text (escapeStringForXML str)
inlineToDocbook opts (Math t str)
  | isMathML (writerHTMLMathMethod opts) = do
    res <- convertMath writeMathML t str
    case res of
         Right r  -> return $ inTagsSimple tagtype
                     $ text $ Xml.ppcElement conf
                     $ fixNS
                     $ removeAttr r
         Left il  -> inlineToDocbook opts il
  | otherwise =
     texMathToInlines t str >>= inlinesToDocbook opts
     where tagtype = case t of
                       InlineMath  -> "inlineequation"
                       DisplayMath -> "informalequation"
           conf = Xml.useShortEmptyTags (const False) Xml.defaultConfigPP
           removeAttr e = e{ Xml.elAttribs = [] }
           fixNS' qname = qname{ Xml.qPrefix = Just "mml" }
           fixNS = everywhere (mkT fixNS')
inlineToDocbook _ (RawInline f x)
  | f == "html" || f == "docbook" = return $ text x
  | otherwise                     = return empty
inlineToDocbook _ LineBreak = return $ text "\n"
-- currently ignore, would require the option to add custom
-- styles to the document
inlineToDocbook _ PageBreak = return empty
inlineToDocbook _ Space = return space
-- because we use \n for LineBreak, we can't do soft breaks:
inlineToDocbook _ SoftBreak = return space
inlineToDocbook opts (Link attr txt (src, _))
  | Just email <- stripPrefix "mailto:" src =
      let emailLink = inTagsSimple "email" $ text $
                      escapeStringForXML $ email
      in  case txt of
           [Str s] | escapeURI s == email -> return emailLink
           _             -> do contents <- inlinesToDocbook opts txt
                               return $ contents <+>
                                          char '(' <> emailLink <> char ')'
  | otherwise =
      (if isPrefixOf "#" src
            then inTags False "link" $ ("linkend", drop 1 src) : idAndRole attr
            else if writerDocbook5 opts
                    then inTags False "link" $ ("xlink:href", src) : idAndRole attr
                    else inTags False "ulink" $ ("url", src) : idAndRole attr )
        <$> inlinesToDocbook opts txt
inlineToDocbook opts (Image attr _ (src, tit)) = return $
  let titleDoc = if null tit
                   then empty
                   else inTagsIndented "objectinfo" $
                        inTagsIndented "title" (text $ escapeStringForXML tit)
  in  inTagsIndented "inlinemediaobject" $ inTagsIndented "imageobject" $
      titleDoc $$ imageToDocbook opts attr src
inlineToDocbook opts (Note contents) =
  inTagsIndented "footnote" <$> blocksToDocbook opts contents

isMathML :: HTMLMathMethod -> Bool
isMathML (MathML _) = True
isMathML _          = False

idAndRole :: Attr -> [(String, String)]
idAndRole (id',cls,_) = ident ++ role
  where
    ident = if null id'
               then []
               else [("id", id')]
    role  = if null cls
               then []
               else [("role", unwords cls)]
