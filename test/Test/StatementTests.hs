module Test.StatementTests (tests_ecmascript5_parser, tests_ecmascript5_parser_with_autosemi) where

import Test.Tasty
import Test.Tasty.HUnit
import System.IO.Unsafe
import Language.ECMAScript5.Syntax.Annotations (reannotate)
import Language.ECMAScript5.Syntax

import Text.Parsec (SourcePos, errorPos, sourceLine, sourceColumn)
import Data.List

import Language.ECMAScript5.PrettyPrint
import Language.ECMAScript5.Parser

tests_ecmascript5_parser :: TestTree
tests_ecmascript5_parser = 
  testGroup "Parser tests" $ unitTests (parseTest False) ++ [whileEmptyTest, commentTest]

-- A re-run all the tests withf automatic semi-colon-insertion

tests_ecmascript5_parser_with_autosemi :: TestTree
tests_ecmascript5_parser_with_autosemi = 
  testGroup "Auto-;-insertion parser tests" $ unitTests (parseTest True)


stripSemis testCase = 
  unlines $ map strip (lines testCase) 
  where 
    strip line = 
      if "for" `isPrefixOf` dropWhile (==' ') line 
        then line
        else filter (/=';') line

infix 1 $$
($$) = ($)

infixr 0 $:
($:) = (:)

deannotate :: [Positioned Statement] -> [Statement ()]
deannotate = map $ reannotate $ const ()

parseTest :: Bool -> String -> [Statement ()] -> Assertion
parseTest replaceSemiColons file ast = 
          do c <- readFile ("test-data/" ++ file ++ ".js")
             let content = if not replaceSemiColons then c else stripSemis c
             let res = parseFromString content
             
             case res of
               Right (Program _ statements) -> assertEqual "Unexpected AST" ast (deannotate statements)
               Left parseError -> assertFailure (show parseError)
     
expectedParseFail :: String -> (Int, Int) -> Assertion
expectedParseFail file (expectedLine, expectedCol) = 
  do content <- readFile ("test-data/" ++ file ++ ".js")
     let res = parseFromString content
     case res of 
       Right value -> assertFailure "Expected parse error"
       Left err -> let pos  = errorPos err
                       line = sourceLine pos
                       col  = sourceColumn pos
                   in do
                    assertEqual "Parse failure at wrong line" line expectedLine
                    assertEqual "Parse failure at wrong column" col expectedCol

whileEmptyTest = 
  testCase "while-empty" $$ 
    (parseTest False) "while-empty" 
    [WhileStmt () (InfixExpr () OpLT (UnaryAssignExpr () PostfixInc (VarRef () (Id () "i"))) (NumLit () (Left 10))) (EmptyStmt ())]

unitTests runTest =
     testCase "Test function definition" $$
       runTest "empty-function" 
       [ExprStmt () (FuncExpr () Nothing [] [])]
  $: testCase "Test function returning function" $$
       runTest "function-return-function" 
       [ExprStmt () (FuncExpr () Nothing [] [ReturnStmt () (Just (FuncExpr () Nothing [] []))])]
  $: testCase "Function w/ body" $$
       runTest "function-with-body"
       [ExprStmt () (FuncExpr () Nothing [] [VarDeclStmt () [VarDecl () (Id () "x") (Just (CallExpr () (VarRef () (Id () "g")) []))],IfStmt () (InfixExpr () OpEq (VarRef () (Id () "x")) (NumLit () (Left 10))) (BlockStmt () [ExprStmt () (AssignExpr () (VarRef () (Id () "x")) OpAssign (NumLit () (Left 20)))]) (EmptyStmt ())])]
  $: testCase "Two statements" $$
       runTest "two-statements"
       [VarDeclStmt () [VarDecl () (Id () "x") (Just (NumLit () (Left 10)))],VarDeclStmt () [VarDecl () (Id () "y") (Just (NumLit () (Left 20)))]]
  $: testCase "Switch statement" $$
       runTest "switch-statements"
       [SwitchStmt () (VarRef () (Id () "foo")) [CaseClause () (NumLit () (Left 10)) [ExprStmt () (CallExpr () (DotRef () (VarRef () (Id () "console")) (Id () "log")) [StringLit () "10!"])],CaseClause () (NumLit () (Left 20)) [ExprStmt () (CallExpr () (DotRef () (VarRef () (Id () "console")) (Id () "log")) [StringLit () "20!"])],CaseDefault () [ExprStmt () (CallExpr () (DotRef () (VarRef () (Id () "console")) (Id () "log")) [StringLit () "something else!"])]]]
  $: testCase "Switch statement w/ two defaults" $$
       expectedParseFail "switch-double-default" (6,12)
  $: testCase "If-statement" $$
       runTest "if-statement"
       [IfStmt () (PrefixExpr () PrefixLNot (InfixExpr () OpEq (VarRef () (Id () "foo")) (VarRef () (Id () "bar")))) (ExprStmt () (AssignExpr () (VarRef () (Id () "x")) OpAssign (NumLit () (Left 10)))) (IfStmt () (InfixExpr () OpNEq (VarRef () (Id () "foo")) (VarRef () (Id () "bar"))) (BlockStmt () [ExprStmt () (AssignExpr () (VarRef () (Id () "x")) OpAssign (NumLit () (Left 20)))]) (BlockStmt () [ExprStmt () (AssignExpr () (VarRef () (Id () "x")) OpAssign (NumLit () (Left 30)))]))]
  $: testCase "Dangling else" $$
       runTest "dangling-else"
       [IfStmt () (VarRef () (Id () "foo")) (ExprStmt () (CallExpr () (VarRef () (Id () "bar")) [])) (EmptyStmt ()),IfStmt () (VarRef () (Id () "bar")) (ExprStmt () (CallExpr () (VarRef () (Id () "cux")) [])) (ExprStmt () (CallExpr () (VarRef () (Id () "baz")) []))]
  $: testCase "For loop" $$
       runTest "for-loop"
       [ForStmt () (VarInit [VarDecl () (Id () "i") (Just (NumLit () (Left 0)))]) (Just (InfixExpr () OpLT (VarRef () (Id () "i")) (NumLit () (Left 10)))) (Just (UnaryAssignExpr () PostfixInc (VarRef () (Id () "i")))) (BlockStmt () [ExprStmt () (CallExpr () (DotRef () (VarRef () (Id () "console")) (Id () "log")) [StringLit () "hello"])])] 
  $: testCase "For-each loop" $$
       runTest "for-each-loop"
       [ForInStmt () (ForInVar (VarDecl () (Id () "i") Nothing)) (VarRef () (Id () "foos")) (BlockStmt () [ExprStmt () (CallExpr () (VarRef () (Id () "foo")) [])])]
  $: testCase "Weird in for-each loop" $$ 
       runTest "weird-in-for-each" 
       [ForInStmt () (ForInVar (VarDecl () (Id () "i") Nothing)) (InfixExpr () OpIn (NumLit () (Left 3)) (ObjectLit () [])) (BlockStmt () [])]
  $: testCase "for (;;)" $$ 
       runTest "empty-for" 
       [ForStmt () NoInit Nothing Nothing (BlockStmt () [])]
  $: testCase "Self-applying function" $$ 
       runTest "self-applying-function" 
       [ExprStmt () (CallExpr () (FuncExpr () Nothing [Id () "foo"] [ReturnStmt () (Just (VarRef () (Id () "foo")))]) [NumLit () (Left 10)])]
  $: testCase "do-while" $$ 
       runTest "do-while" 
       [DoWhileStmt () (BlockStmt () [ExprStmt () (UnaryAssignExpr () PrefixInc (VarRef () (Id () "i")))]) (InfixExpr () OpGT (VarRef () (Id () "i")) (NumLit () (Left 10)))]
  $: testCase "while-loop" $$ 
       runTest "while" 
       [WhileStmt () (InfixExpr () OpLT (VarRef () (Id () "i")) (NumLit () (Left 10))) (BlockStmt () [ExprStmt () (UnaryAssignExpr () PrefixInc (VarRef () (Id () "i")))])]
  $: testCase "new/member" $$
       runTest "new-member" 
       [ExprStmt () (NewExpr () (VarRef () (Id () "jQuery")) [VarRef () (Id () "selector"),VarRef () (Id () "context"),VarRef () (Id () "rootjQuery")])]
  $: testCase "new-expression with no constructor call" $$
       runTest "new-expression" 
       [ExprStmt () (InfixExpr () OpAdd (NewExpr () (VarRef () (Id () "jQuery")) []) (NumLit () (Left 10)))]
  $: testCase "new-expression precedence" $$
       runTest "new-expression-precedence" 
       [ ExprStmt () (NewExpr () (BracketRef () (VarRef () (Id () "obj")) (VarRef () (Id () "foo"))) [VarRef () (Id () "bar")])
       , ExprStmt () (BracketRef () (NewExpr () (DotRef () (VarRef () (Id () "foo")) (Id () "bar")) [VarRef () (Id () "cux")]) (VarRef () (Id () "qux")))]
  $: testCase "NoLineTerminatorHere in post increment (i++)" $$
       runTest "postinc-autosemi"
       [ ExprStmt () $ VarRef () $ Id () "i"
       , ExprStmt () $ UnaryAssignExpr () PrefixInc $ VarRef () $ Id () "j" ]
  $: testCase "NoLineTerminatorHere in the return statement" $$
       runTest "return-autosemi"
       [ ReturnStmt () Nothing
       , ExprStmt () $ VarRef () $ Id () "x" ]
  $: testCase "Example 1 from spec 7.9.2 (failing)" $$
       expectedParseFail "7.9.2-1" (1,5)
  $: testCase "Example 2 from spec 7.9.2" $$
       runTest "7.9.2-2"
       [ BlockStmt () [ ExprStmt () $ NumLit () $ Left 1
                      , ExprStmt () $ NumLit () $ Left 2 ]
       , ExprStmt () $ NumLit () $ Left 3 ]
  $: testCase "Example 3 from spec 7.9.2 (failing)" $$
       expectedParseFail "7.9.2-3" (2,1)
  $: testCase "Example 4 from spec 7.9.2" $$
       runTest "7.9.2-4"
       [ ReturnStmt () Nothing
       , ExprStmt () $ InfixExpr () OpAdd (VarRef () $ Id () "a") (VarRef () $ Id () "b")]
  $: testCase "Example 5 from spec 7.9.2" $$
       runTest "7.9.2-5"
       [ ExprStmt () $ AssignExpr () (VarRef () $ Id () "a") OpAssign (VarRef () $ Id () "b")
       , ExprStmt () $ UnaryAssignExpr () PrefixInc (VarRef () $ Id () "b") ]
  $: testCase "Example 6 from spec 7.9.2 (failing)" $$
       expectedParseFail "7.9.2-6" (2,1)
  $: testCase "Example 7 from spec 7.9.2" $$
       runTest "7.9.2-7"
       [ ExprStmt () $ AssignExpr () (VarRef () $ Id () "a") OpAssign $
         InfixExpr () OpAdd (VarRef () $ Id () "b") $
         CallExpr () (InfixExpr () OpAdd (VarRef () $ Id () "d") (VarRef () $ Id () "e")) [] ]
  $: []


commentTest =
  testCase "line comments" $$
  (parseTest False) "line-comments"
  [ExprStmt () (NumLit () (Right 3.2))]

jQuery = testCase "jQuery doesn't fail to parse" $$
         (parseTest False) "jquery"
         []

run = defaultMain tests_ecmascript5_parser
runa = defaultMain tests_ecmascript5_parser_with_autosemi 