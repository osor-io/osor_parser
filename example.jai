#import "Basic";
#import "Hash";
#import "Hash_Table";
#import,dir "../osor_parser";



main :: ()
{
    simple_parsing();
    simple_unparsing();
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
    test_enum = VALUE_C // You can put enum names directly, the name will be matched and filled with the value

    test_enum_flags = THESE | ARE | FLAGS | 0xF000 // You can put flags into an enum flags with '|'

    a_string_id = "This string will be hashed" // String_IDs are parsed with our custom_struct_parsing 

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
    DONE

    result : Big_Boy_Test;
    success, error := parse(TEST_STRING, *result, PARSE_SETTINGS_WITH_ALLOCATIONS, custom_struct_parsing); // See custom_struct_parsing below
    if !success then log_error(error);
    assert(<<result.pointer_to_int == 99119911);
    print("Whole struct = %\n", formatStruct(result,use_newlines_if_long_form=true));
    print("Dereferencing pointer to an int = %\n", <<result.pointer_to_int);
    print("Dereferencing pointer to complex data = %\n", <<result.pointer_to_some_more_data);
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

    builder : String_Builder;
    defer reset(*builder);
    success, error := unparse(*builder, *test, custom_struct_unparsing); // See custom_struct_unparsing below
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
// Custom parsing!
//
// You can detect certain struct types and parse them yourself.
//
// This is useful for cases where you have a type that you want a certain
// runtime structure for, but want them to exist in the string in a different
// form.
//
// My prime example for this is a "hashed string"/"string id", so I'm demoing it with that here.
//
// A quick search shows some examples of this such as:
//
// - https://github.com/foonathan/string_id 
// - https://github.com/TheAllenChou/string-id
//
// The idea is that instead of loading in "a_string_literal", you hash that into a 
// constant sized integer value and use that instead to work with, with all the speed benefits
// of working with integers instead of strings.
//
//                                        - Ruben Osorio, 15/01/2023
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
custom_struct_parsing :: () -> bool #expand
{
    if `struct_info == type_info(String_ID) && `token.type == .String
    {
        string_id : String_ID;
        string_id.hash = get_hash(`token.text);
        assert(`struct_info.runtime_size == size_of(type_of(string_id)));
        memcpy(`value_pointer, *string_id, size_of(type_of(string_id)));
        `token += 1; 
        return true; // Return true if you've handled this struct in your code
    }
    return false; // And return false if you haven't handled this struct and the generic code should do it
}
custom_struct_unparsing :: () -> bool #expand
{
    if `struct_info == type_info(String_ID)
    {
        string_id_pointer := cast(*String_ID)`value_pointer;
        original_string := table_find_pointer(*string_id_map, string_id_pointer.hash);
        if original_string
        {
            append(`builder, "\"");
            append(`builder, <<original_string);
            append(`builder, "\"");
        }
        else
        {
            assert(false);
            append(`builder, "");
        }
        return true;
    }
    return false;
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


