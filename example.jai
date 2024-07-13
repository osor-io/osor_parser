#import "Basic";
#import "Math";
#import "Hash";
#import "Hash_Table";
#import "osor_tokenizer"; // https:/github.com/osor-io/osor_tokenizer
#import,dir "../osor_parser";



main :: ()
{
    simple_parsing();
    simple_unparsing();
    custom_parsing_and_unparsing();
    float_unparsing_and_parsing();
    // @@TODO: example of custom allocation when parsing
    big_boy_parsing();
    big_boy_unparsing();
}



simple_parsing :: ()
{
    print_example_name("Simple data parsing");

    Test :: struct
    {
        a : int;
        b : float;
        c : string;
        d := 4; 
    }

    DATA :: #string DONE
    a = 1
    b = 2.0
    c = "three"
    // Because we don't put "d" here, it'll be left as it was
    DONE

    test : Test;
    success, error := parse(DATA, *test);
    if !success then log_error(error);
    print("%\n", test);
}



simple_unparsing :: ()
{
    print_example_name("Simple data unparsing");

    Test :: struct
    {
        a : int;
        b : float;
        c : string;
        d := 4; 
    }

    test : Test;
    test.a = 1;
    test.b = 2.0;
    test.c = "three";

    builder : String_Builder;
    defer reset(*builder);
    success, error := unparse(*builder, *test);
    the_string := builder_to_string(*builder);

    print("%\n", the_string);
}



custom_parsing_and_unparsing :: ()
{
    print_example_name("Custom Parsing & Unparsing");

    Test :: struct
    {
        a : Three_Ints;
        b : Three_Ints;
    }

    Three_Ints :: struct
    {
        x : int;
        y : int;
        z : int;
    }

    custom_parse :: (token : *Token, struct_info : *Type_Info_Struct, value_pointer : *void) -> bool, *Token, string
    {
        if struct_info == type_info(Three_Ints)
        {
            three_ints := cast(*Three_Ints)value_pointer;

            assert(token.type == .INTEGER);
            three_ints.x = string_to_int(token.text); 
            token += 1;

            assert(token.type == .INTEGER);
            three_ints.y = string_to_int(token.text); 
            token += 1;

            assert(token.type == .INTEGER);
            three_ints.z = string_to_int(token.text); 
            token += 1;

            return true, token, "";
        }
        return false, null, "";
    }

    custom_unparse :: (builder : *String_Builder, struct_info : *Type_Info_Struct, value_pointer : *void) -> bool, string
    {
        if struct_info == type_info(Three_Ints)
        {
            three_ints := cast(*Three_Ints)value_pointer;
            print_to_builder(builder, "% % %", three_ints.x, three_ints.y, three_ints.z);
            return true, "";
        }
        return false, "";
    }

    DATA :: #string DONE
    a = 0 1 2 
    b = 123 456 789
    DONE

    print("Original string to parse was:\n%\n\n", DATA);

    test : Test;
    success, error := parse(DATA, *test, Parse_Settings.{extra_custom_parsers = .[custom_parse]});
    if !success then log_error(error);
    print("Parsed string into this data type:\n%\n\n", test);

    builder : String_Builder;
    defer reset(*builder);
    success, error = unparse(*builder, *test, Unparse_Settings.{extra_custom_unparsers = .[custom_unparse]});
    the_string := builder_to_string(*builder);
    print("Unparsed the data type back to this string:\n%\n", the_string);
}



float_unparsing_and_parsing :: ()
{
    print_example_name("Floating-Point Number Unparsing & Parsing");

    Test :: struct
    {
        a : float;
        b : float64;
    }

    test : Test;
    test.a = 3.1415927;
    test.b = 3.141592653589793;

    unparse_and_parse_back :: (output_floats_as_binary : bool) #expand
    {
        unparse_settings := Unparse_Settings.{
            float_output_mode = ifx output_floats_as_binary then .BINARY_WITH_COMMENT else .FLOAT_ONLY,
        };

        builder : String_Builder;
        defer reset(*builder);
        success, error := unparse(*builder, *test, unparse_settings);
        the_string := builder_to_string(*builder);
        print("Unparsed the data with floats into this:\n%\n", the_string);

        readback : Test;
        success, error = parse(the_string, *readback);
        if !success then log_error(error);
        print("When read back the data is this:\na = %\nb = %\n\n", FormatFloat.{value = readback.a, trailing_width = 20}, FormatFloat.{value = readback.b, trailing_width = 20});

        data_matches := memcmp(*test, *readback, size_of(Test)) == 0;
        print("Does it match the original data?\n%\n\n", data_matches);

        if output_floats_as_binary
        {
            assert(data_matches);
            print("Because we're outputting the binary representation of the floats and reading them back they will always match.\n\n");
        }
        else
        {
            print("Because we're outputting floats as literals and those are iffy to write and to parse back,\nthere can be imprecissions so the data we read back might not match the original\n\n");
        }
    }
    unparse_and_parse_back(false);
    unparse_and_parse_back(true);
}



big_boy_parsing :: ()
{
    print_example_name("Parsing everything but the kitchen sink");

    TEST_STRING :: #string DONE
    /*
    Note how the members here don't have to be in order.

    Also, formatting doesn't matter for anything, whitespace and newlines don't affect parsing.
    And comments like this one don't either.

    You can use Jai block comments with "/**/" or line comments with "//"
    */

    //
    // We can indicate with a number before the bracket the count on the array
    //
    //                   See here
    //                      |
    //                      v
    dynamic_array_of_ints = 6 [1 2 3 -1 -2 -3] // commas between elements are optional in arrays

    dynamic_array = [ // You can make dynamic arrays with any type, this can be added to too after initialization
        {
            value_integer = 0
        },
        {
            value_integer = 2
        },
        {
            value_integer = 4
        },
        {
            value_integer = 999
        },
    ]

    /*
    You can have all types of arrays:

    []int and [..]int will both allocate, you can put the number before the bracket to only allocate once

    [3]int will not allocate, since the data is already on the struct, it will require you give that number of arguments
    */

    static_size_array = [3, 4, 12312312] // This comes from a 'using' but it still can be put at the top level

    pointer_to_int = 99119911 // This will allocate an int then fill it with the proper value
    pointer_to_some_more_data = {
        hello_again = 666666666
        some_strings = ["wow if this works this is ", "sick", "as", "hell"]
    }
    a = 3
    variant = 0x99887722
    one_of_these = {
        hello_again = 999999999
    }
    hello_again = 101010
    data_2 = 0b1010_0101_1111 
    defaults_to_3 = 4444444444
    enabled = true

    /*
    You can also put comments like these
        /*
        And even /*nested*/ if you want!
        */
        // This is fine too
    */

    b = 123123.0

    //
    // If a float is followed by # and an integer, it'll try to use the integer as the byte representation of a float64, 
    // this is because if you load and save the same float multiple times, you can get to imprecission issues when
    // reading and writing it that can end up with the same value being changed every time you save/load. This creates
    // confusion and lots of diffs on files that are saved and loaded often.
    //
    b2 = -123.123001 # 0xc05ec7df40000000 // Remove the # and the number after it when editing 

    d = ["string a", "string b"]
    c = "why not another string"

    a_character = 'E'
    an_emoji = '🤗'

    test_enum = VALUE_C // You can put enum names directly, the name will be matched and filled with the value

    test_enum_flags = THESE | ARE | FLAGS | 0xF000 // You can put flags into an enum flags with '|'

    a_string_id = "This string will be hashed" // String_IDs are parsed with our string_id_parsing() 

    array_of_structs = [
        {
            data_1 = 8
            data_2 = 10
        },
        {
            data_2 = 8
            data_1 = 10
            data_4 = 31
            data_3 = 12
            some_strings = ["test string", "and another one",]
        },
    ]


    dynamic_array_of_floats = [1, +2, 4, -123123.0123, 123.123123, -0.0, +0.0, -.123, 0.1]

    string_id_array = [ // You can even make an array of string ids, put some as strings and put some directly with the hash!
        "testting 111",
        "testting asdfk111",
        { hash = 123123123 }
        "another_one",
    ]
    
    // These are parsed with vector_parsing()
    some_vector3 = (0,1,2)
    random_quaternion = (0.603, -0.056, 0.603, 0.519) 
    DONE

    result : Big_Boy_Test;
    settings := Parse_Settings.{allocators = .[CONTEXT_PARSER_ALLOCATOR], copy_strings = true, extra_custom_parsers = .[vector_parsing, string_id_parsing]}; // See section about "User-Level Custom Parsing" below
    success, error := parse(TEST_STRING, *result, settings);
    if !success then log_error(error);
    assert(result.pointer_to_int.* == 99119911);
    print("Whole struct = %\n", formatStruct(result,use_newlines_if_long_form=true));
    print("Dereferencing pointer to an int = %\n", result.pointer_to_int.*);
    print("Dereferencing pointer to complex data = %\n", result.pointer_to_some_more_data.*);
    print("Messing with the dynamically allocated array on the struct:\n");
    print("  The dynamic array before adding some elements: %\n", result.dynamic_array);
    print("  Allocated count before adding some elements: %\n", result.dynamic_array.allocated);
    for 0..15 array_add(*result.dynamic_array, .{});
    print("  The dynamic array after adding some elements: %\n", result.dynamic_array);
    print("  Allocated count after adding some elements: %\n", result.dynamic_array.allocated);
}



big_boy_unparsing :: ()
{
    print_example_name("Unparsing everything but the kitchen sink");

    test : Big_Boy_Test;
    test.test_enum = .VALUE_C;
    test.test_enum_flags = Big_Boy_Test.Test_Enum_Flags.THESE | .ARE | .FLAGS | 0x8000;
    test.a = 123;
    test.b = -123.123;
    test.c = "a string";
    test.d = .["a", "b", "c", "easy as", "one", "two", "three"];
    test.a_character = #char "E";
    test.an_emoji = #char "🤗";
    test.variant = 0xFFAA;
    test.array_of_structs = .[ .{}, .{}, .{data_1 = 123, data_4 = 100, some_strings = .["some", "strings"]}];
    test.one_of_these.data_1 = 11111;
    test.one_of_these.data_2 = 2313242;
    array_add(*test.dynamic_array, .{0});
    array_add(*test.dynamic_array, .{2});
    array_add(*test.dynamic_array, .{4});
    array_add(*test.dynamic_array, .{999});
    array_add(*test.dynamic_array_of_ints, 0);
    array_add(*test.dynamic_array_of_ints, 2);
    array_add(*test.dynamic_array_of_ints, 3);
    array_add(*test.dynamic_array_of_ints, 666);
    array_add(*test.dynamic_array_of_floats, 0.5);
    array_add(*test.dynamic_array_of_floats, 2.5);
    array_add(*test.dynamic_array_of_floats, 3.5);
    array_add(*test.dynamic_array_of_floats, 666.6);
    the_int := 9494;
    test.pointer_to_int = *the_int;
    some_more_data := Big_Boy_Test.Some_More_Data.{hello_again = 5151, defaults_to_3 = 44444};
    test.pointer_to_some_more_data = *some_more_data;
    test.include_me.enabled = true;
    test.include_me.hello_again = 44554455;
    test.a_string_id = make_string_id("yo this is a string id");
    test.some_vector3 = .{123, 456, 123.456};
    set_from_axis_and_angle(*test.random_quaternion, Vector3.{0,0,1}, PI/2);

    builder : String_Builder;
    defer reset(*builder);
    settings := Unparse_Settings.{extra_custom_unparsers = .[vector_unparsing, string_id_unparsing]}; // See section about "User-Level Custom Parsing" below
    success, error := unparse(*builder, *test, settings);
    the_string := builder_to_string(*builder);

    print("%\n", the_string);
}



Big_Boy_Test :: struct
{
    test_enum := Test_Enum.HELLO;
    test_enum_flags : Test_Enum_Flags;
    a := 1;
    b := 1.0;
    b2 := 1.0;
    c := "just a string";
    d : [] string;
    a_character : u8;
    an_emoji : u32;
    variant : A_Testing_Variant = xx 1122334455;
    array_of_structs : [] Some_More_Data;
    one_of_these : Some_More_Data;

    dynamic_array : [..] Simple;

    dynamic_array_of_ints : [..] int;

    dynamic_array_of_floats : [..] float32;

    pointer_to_int : *int;

    pointer_to_some_more_data : *Some_More_Data;

    using include_me : Include_Me;

    a_string_id : String_ID;

    string_id_array : [4] String_ID;

    A_Testing_Variant :: #type,distinct u64;

    some_vector3 : Vector3;
    random_quaternion : Quaternion;

    Test_Enum :: enum
    {
        HELLO;
        VALUE_A;
        VALUE_B :: 123;
        VALUE_C;
    }

    Test_Enum_Flags :: enum_flags
    {
        YO;
        THESE;
        HEY;
        ARE;
        WADDUP;
        FLAGS;
        THESE_ARE :: THESE | ARE;
        ARE_FLAGS :: ARE | FLAGS;
        THESE_ARE_FLAGS :: THESE | ARE | FLAGS;
        YO_THESE_ARE_FLAGS :: YO | THESE | ARE | FLAGS;
    }

    Simple :: struct
    {
        value_integer := 123;
    }

    Some_More_Data :: struct
    {
        data_1 : u64;
        data_2 : u32;
        hello_again := 123;
        defaults_to_3 := 3333333;
        data_3 : u16;
        data_4 : s8;
        some_strings : [] string;
    }

    Include_Me :: struct
    {
        static_size_array : [3] int = .[1, 2, 3];
        enabled := false;
        data_2 : u32;
        hello_again := 123;
        something_to_pad := 123321;
        defaults_to_3 := 3333333;
    }
}



//
// User-Level Custom Parsing!
//
// You can detect certain struct types and parse/unparse them yourself.
//
// This is useful when you might want some extra niceness on the string
// representation of some data types, instead of what the default parsing/unparsing
// code would have read/written.
//
// In this case we're going to do something different for the classic mathematical
// vector types. The default code would have written this for a vector 3:
//
//
//   some_vector3 = {
//       x =  123                 # 0x405ec00000000000
//       y =  456                 # 0x407c800000000000
//       z =  123.456001281738281 # 0x405edd2f20000000
//   }
//
//
// Because as far as the module code is aware, this is just another struct with some
// floats inside. But this might be very frequent in our files, and we might want to make
// them more compact, or nicer to edit. So we're going to make it so instead of that above
// we're going to parse the following format:
//
//
//   some_vector3 = (123, 456, 123.456)
//
//
// Also very handy for cases where you have a type that you want a certain
// runtime structure for, but want them to exist in the string to parse in
// a different form. This is the case with the String_ID data type below.
//
vector_parsing :: (token : *Token, struct_info : *Type_Info_Struct, value_pointer : *void) -> parsed : bool, next_token : *Token, error : string
{
    if struct_info == type_info(Vector2) || struct_info == type_info(Vector3) || struct_info == type_info(Vector4) || struct_info == type_info(Quaternion)
    {
        components := cast(*float)value_pointer;
        component_count := struct_info.runtime_size / size_of(float);
        if token.type != .OPEN_PARENTHESES then return false, null, "Missing initial open parentheses";
        token += 1;
        component_index := 0;
        while true 
        {
            sign := 1.0;
            if token.type == .MINUS
            {
                sign = -1.0; 
                token += 1;
            }
            if !(token.type == .FLOAT || token.type == .INTEGER) then return false, null, tprint("Expected a number but found %", token.type);
            if component_index < component_count
            {
                components[component_index] = sign * cast(float)string_to_float64(token.text);;
                component_index += 1;
                token += 1;
            }
            else
            {
                return false, null, "Trying to write too many components for this type";
            }
            if token.type == .CLOSE_PARENTHESES
            {
                break;
            }
            if token.type == .COMMA
            {
                token += 1;
            }
        }
        token += 1;
        return true, token, "";
    }
    return false, null, "";
}
vector_unparsing :: (builder : *String_Builder, struct_info : *Type_Info_Struct, value_pointer : *void) -> unparsed : bool, error : string
{
    if struct_info == type_info(Vector2) || struct_info == type_info(Vector3) || struct_info == type_info(Vector4) || struct_info == type_info(Quaternion)
    {
        components := cast(*float)value_pointer;
        component_count := struct_info.runtime_size / size_of(float);
        append(builder, "(");
        for 0..component_count-1
        {
            if it > 0 then append(builder, ", ");
            print_to_builder(builder, "%", components[it]);
        }
        append(builder, ")");
        return true, "";
    }
    return false, "";
}



//
// User-level code to parse and unparse "hashed string"/"string id" types
//
// Some examples of what these are in here:
//
// - https://github.com/foonathan/string_id 
// - https://github.com/TheAllenChou/string-id
//
// The idea is that instead of loading in "a_string_literal", you hash that into a 
// constant sized integer value and use that instead to work with, with all the speed benefits
// of working with integers instead of strings.
//
String_ID :: struct { hash : u64 = 0; }
string_id_map : Table(u64, string);
make_string_id :: (s : string) -> String_ID
{
    result : String_ID;
    result.hash = get_hash(s);
    table_add(*string_id_map, result.hash, copy_string(s));
    return result;
}
string_id_parsing :: (token : *Token, struct_info : *Type_Info_Struct, value_pointer : *void) -> parsed : bool, next_token : *Token, error : string
{
    if struct_info == type_info(String_ID) && token.type == .STRING
    {
        string_id : String_ID;
        string_id.hash = get_hash(token.text);
        assert(struct_info.runtime_size == size_of(type_of(string_id)));
        memcpy(value_pointer, *string_id, size_of(type_of(string_id)));
        token += 1; 
        return true, token, ""; // Return true if you've handled this struct in your code
    }
    return false, null, ""; // And return false if you haven't handled this struct and the generic code should do it
}
string_id_unparsing :: (builder : *String_Builder, struct_info : *Type_Info_Struct, value_pointer : *void) -> unparsed : bool, error : string
{
    if struct_info == type_info(String_ID)
    {
        string_id_pointer := cast(*String_ID)value_pointer;
        original_string := table_find_pointer(*string_id_map, string_id_pointer.hash);
        if original_string
        {
            append(builder, "\"");
            append(builder, original_string.*);
            append(builder, "\"");
        }
        else
        {
            assert(false);
            append(builder, "");
        }
        return true, "";
    }
    return false, "";
}



#scope_file



print_example_name :: (name : string) #expand
{
    for 0..(8 + name.count)-1 print("#");
    print("\n### % ###\n", name);
    for 0..(8 + name.count)-1 print("#");
    print("\n");
    `defer print("\n\n\n");
}


