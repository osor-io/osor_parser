//
// This is a parser to go from string to an arbitrary instance of a given struct.
//
// There's an example in example.jai where we test some of the features which are:
//
// - Parsing all basic types and copying the values directly into the struct.
// - Parsing arrays, that being fixed, dynamic or views. Allocating only for dynamic and views.
// - Parsing enums, it can find the name, match it to the value and write it to the result.
// - Parsing strings, either pointing to the provided string or copying the string.
// - Parsing pointers, allocating the needed type and filling it. There's a custom pointer_allocator
//   that can be provided, so the memory for a given type is provided by the user.
// - Parsing nested structs and handling 'using' correctly. This means that at the base struct level
//   you can put the name of a member living on a child struct that is marked with 'using'.
// - Option to specify how many elements are on an array to only allocate once 'array = 3 [1,2,3]'.
// - Option to provide custom parsing procedures.
//
//
// Considerations:
//
// - Currently if you parse the same member multiple times it'll overwrite it with the last one,
//   which means that if you put something like a string or an array twice you might be leaking that memory.
//
// - If we fail to parse for some reason and throw an error, this will NOT clean up the struct and the
//   members that it already allocated. So in an error case you might be leaking memory as well. 
//
// - During the tokenization process this will allocate memory for the tokens that is freed when returning
//   from the procedure always thanks to defer. That will never leak, but is a consideration to have, 
//   especially if you're providing a custom allocator in the context.
//
//
// Other possible improvements
//
// - We could give the option to provide an instance of a struct that only patch the members that are found
//   on the file. If there are pointers or arrays, it would reuse the memory from those (reallocating the arrays
//   if necessary). This is not useful however if you are removing fields from a file you already loaded cause
//   it would leave them there as they were (not default initializing them again). But this might have its uses.
//
//



//
// @@TODO: Ideally we'd like to pass the default custom parsers/unparsers from the user via
// module parameters as follows: 
//
//     #module_parameters(CUSTOM_PARSERS : []Custom_Parser = .[], CUSTOM_UNPARSERS : []Custom_Unparser = .[])
//     {
//         Custom_Parser :: #type (token : *Token, struct_info : *Type_Info_Struct, value_pointer : *void) -> parsed : bool, next_token : *Token, error : string;
//         Custom_Unparser :: #type (builder : *String_Builder, struct_info : *Type_Info_Struct, value_pointer : *void) -> unparsed : bool, error : string;
//     }
//
// However this is triggering an internal compiler error at the time of writing. Once that's fixed
// we sould be able to just enable the line above. For the time being, by default there's no module-wide
// custom parsers/unparsers.  
//
// If you do want to use them already, you can set the EXPECT_CUSTOM_PARSERS module parameter to true and provide them via
// #poke_name to the procedure as in:
//
//     using Osor_Parser :: #import "osor_parser"(EXPECT_CUSTOM_PARSERS = true);
//     CUSTOM_PARSERS   : []Custom_Parser   = .[/*your custom parsing procedures*/];
//     CUSTOM_UNPARSERS : []Custom_Unparser = .[/*your custom unparsing procedures*/];
//     #poke_name Osor_Parser CUSTOM_PARSERS;
//     #poke_name Osor_Parser CUSTOM_UNPARSERS;
//
#module_parameters(EXPECT_CUSTOM_PARSERS := false);
#if !EXPECT_CUSTOM_PARSERS
{
    CUSTOM_PARSERS   : []Custom_Parser   = .[];
    CUSTOM_UNPARSERS : []Custom_Unparser = .[];
}



#import "Basic";
#import "String";
#import "osor_tokenizer"; // https:/github.com/osor-io/osor_tokenizer



Parse_Settings :: struct
{
    copy_strings := false; 
    // If false, the strings on the result will just be slice of the provided input string,
    // otherwise they'll be allocated through the set of allocators in here. Note that the
    // size and old_size given to the allocator procedure is the length in bytes of the string,
    // even if it's sending the type_info of the string itself (so you know it's a string in case
    // you want to allocate those differently than random byte arrays).

    allocators : []Parser_Allocator;
    // This is an array of allocators that will be called whenever dynamic memory is needed. It 
    // will do it in-order, and each can choose to return false to not handle the allocation.
    //
    // The idea is that you might not want unlimited dynamic allocations when parsing, but you might
    // have some data types that want to go to a separate buffer, or use a separate pool or something, in
    // these cases you can set up an allocator and only handle allocations for a specific type (since the
    // allocator procedure for these receives a *Type_Info).
    //
    // Then if you DO want general dynamic allocation, you can hook up the context allocator or the
    // basic allocator at the end of the array. You can see how CONTEXT_PARSER_ALLOCATOR is used to
    // achieve this. This way, all the allocations that are not for specific types will fall naturally
    // to the generic allocator and be handled in a more traditional way.
    //

    extra_custom_parsers : []Custom_Parser;
    // If you want a particular call to use further custom parsing procedures in addition
    // to the ones in the module parameters, you can specify them here.
}

Parser_Allocator_Procedure :: #type (info : *Type_Info, count : s64, old_count : s64, old_memory : *void, allocator_data : *void) -> handled : bool, *void;
Parser_Allocator :: struct
{
    procedure : Parser_Allocator_Procedure;
    data : *void;
}
CONTEXT_PARSER_ALLOCATOR :: Parser_Allocator.{
    procedure = (info : *Type_Info, count : s64, old_count : s64, old_memory : *void, allocator_data : *void) -> bool, *void
    {
        allocator := context.allocator;
        size := info.runtime_size * count;
        if old_count > 0 || old_memory != null
        {
            old_size := info.runtime_size * old_count;
            return true, realloc(old_memory, size, old_size,, allocator);
        }
        return true, alloc(size,, allocator);
    },
    data = null,
};

Custom_Parser :: #type (token : *Token, struct_info : *Type_Info_Struct, value_pointer : *void) -> parsed : bool, next_token : *Token, error : string;

PARSE_SETTINGS_WITH_GENERIC_ALLOCATIONS :: Parse_Settings.{
    copy_strings = true,
    allocators = .[CONTEXT_PARSER_ALLOCATOR],
};

parse :: (the_string : string, result : *$Result_Type, settings := Parse_Settings.{}) -> success : bool, error : string
{
    success, error := parse(the_string, cast(*void)result, type_info(Result_Type), settings);
    return success, error;
}
parse :: (the_string : string, result : *void, result_type_info : *Type_Info_Struct, settings := Parse_Settings.{}) -> success : bool, error : string
{
    parse_one :: (token : *Token, info : *Type_Info, value_pointer : *void, settings : Parse_Settings, custom_parsers : []Custom_Parser, is_first_call := false) -> *Token #must, success : bool #must, error : string #must
    {
        error :: (token : *Token, format : string, arguments : .. Any) -> string
        {
            user_message := tprint(format, ..arguments);
            complete_message := tprint("%\n    line %: %\n", user_message, token.line.number, token.line.text);
            return complete_message;
        } @PrintLike

        integer_fits_in_type :: (unsigned_value : u64, negated : bool, integer_info : *Type_Info_Integer) -> bool
        {
            if negated && !integer_info.signed then return false;
            max_unsigned_value : u64 = 0;
            for 0..integer_info.runtime_size-1 
            {
                max_unsigned_value <<= 8;
                max_unsigned_value |= 0xFF;
            }
            if integer_info.signed 
            {
                max_unsigned_value >>= 1;
                if negated then max_unsigned_value += 1;
            }
            return unsigned_value < max_unsigned_value;
        }

        if #complete info.type == 
        {
            case .INTEGER;
            info_int := cast(*Type_Info_Integer) info;
            negate := false;
            if token.type == .PLUS  
            {
                token += 1;
            }
            else if token.type == .MINUS 
            {
                negate = true;
                token += 1;
            }
            if token.type != .INTEGER
            {
                return null, false, error(token, "Expected Integer but found %", token.type);
            }
            value, integer_parse_success, integer_parse_error := token_to_integer(token);
            if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %", integer_parse_error);
            if !integer_fits_in_type(value, negate, info_int) return null, false, error(token, "Integer doesn't fit in this type");
            if info_int.signed  
            {
                signed_value := cast(s64)value;
                if negate then signed_value = -signed_value;
                if      info.runtime_size == 1 { v := cast(s8)  signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast(s16) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast(s32) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast(s64) signed_value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            else
            {
                if negate then return null, false, error(token, "Setting negative value (%) on unsigned member", value);
                if      info.runtime_size == 1 { v := cast(u8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast(u16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast(u32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast(u64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            token += 1;



            case .FLOAT;
            value : float64;
            has_value := false;
            if token.type == .PLUS || token.type == .MINUS || token.type == .FLOAT || token.type == .INTEGER
            {
                negate := false;
                while token.type == .PLUS || token.type == .MINUS
                {
                    if token.type == .MINUS then negate = !negate;
                    token += 1;
                }
                if token.type == .FLOAT || token.type == .INTEGER
                {
                    parsed_value, success, remainder := string_to_float64(token.text);
                    if !success             then return null, false, error(token, "Couldn't parse float from this string");
                    if remainder.count != 0 then return null, false, error(token, "Didn't use the full string when parsing this float, results will be incorrect");
                    value = ifx negate then -parsed_value else parsed_value;
                    has_value = true;
                    token += 1;
                }
                else
                {
                    return null, false, error(token, "Expected Integer or Float but found %", token.type);
                }
            }
            else if token.type == .HASH
            {
                token += 1;
                if token.type == .INTEGER
                {
                    parsed_value, integer_parse_success, integer_parse_error := token_to_integer(token);
                    if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %", integer_parse_error);
                    value = (cast(*float64)(*parsed_value)).*;
                    has_value = true;
                    token += 1;
                }
                else
                {
                    return null, false, error(token, "Expected Integer as the int representation of a float (after a #) but found %", token.type);
                }
            }
            else
            {
                return null, false, error(token, "Expected the a float number, either a float literal or a binary one starting with #, but got % instead", token.type);
            }
            if !has_value
            {
                return null, false, error(token, "Attempting to parse a float but we couldn't find any values here");
            }
            if info.runtime_size == 8
            {
                assert(info.runtime_size == size_of(type_of(value)));
                memcpy(value_pointer, *value, size_of(type_of(value)));
            }
            else if info.runtime_size == 4
            {
                value_32 := cast(float32) value;
                assert(info.runtime_size == size_of(type_of(value_32)));
                memcpy(value_pointer, *value_32, size_of(type_of(value_32)));
            }
            else assert(false);



            case .BOOL;
            if token.type != .BOOL
            {
                return null, false, error(token, "Expected Bool but found %", token.type);
            }
            value := false;
            if      compare_nocase(token.text, "true") == 0
                value = true;
            else if compare_nocase(token.text, "false") == 0
                value = false;
            else assert(false);
            assert(info.runtime_size == size_of(type_of(value)));
            memcpy(value_pointer, *value, size_of(type_of(value)));
            token += 1;



            case .STRING;
            the_string : string;
            if token.type != .STRING
            {
                return null, false, error(token, "Expected String but found %", token.type);
            }
            if settings.copy_strings
            {
                alloc_success := false;
                alloc_success, the_string.data = parser_alloc(*settings, type_info(type_of(the_string.data.*)), token.text.count + 1);
                if !alloc_success
                {
                    return null, false, error(token, "Requested to copy a string but we couldn't allocate memory for the copy");
                }
                the_string.count = token.text.count;
                memcpy(the_string.data, token.text.data, token.text.count);
                (the_string.data + the_string.count).* = #char "0";
            }
            else
                the_string = token.text;
            assert(info.runtime_size == size_of(type_of(the_string)));
            memcpy(value_pointer, *the_string, size_of(type_of(the_string)));
            token += 1;



            case .ENUM;
            enum_info := cast(*Type_Info_Enum) info;
            value : type_of(enum_info.values[0]);
            first_enum_token := token;
            while true
            {
                if token.type == .IDENTIFIER
                {
                    enum_index := -1;
                    for enum_info.names  
                        if it == token.text  
                            enum_index = it_index;
                    if enum_index < 0
                    {
                        return null, false, error(token, "Enum value % didn't match any of the possible values for %", token.text, enum_info.name);
                    }
                    value |= enum_info.values[enum_index];
                }
                else
                {
                    negate := false;
                    if token.type == .PLUS  
                    {
                        token += 1;
                    }
                    else if token.type == .MINUS 
                    {
                        negate = true;
                        token += 1;
                    }
                    if token.type == .INTEGER
                    {
                        int_value, integer_parse_success, integer_parse_error := token_to_integer(token);
                        if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
                        if !integer_fits_in_type(int_value, negate, enum_info.internal_type) return null, false, error(token, "Integer doesn't fit in the internal type of this enum");
                        if negate then value |= xx -(cast(s64)int_value);
                                  else value |= xx int_value;
                    }
                    else
                    {
                        return null, false, error(token, "Expected Identifier but found %", token.type);
                    }
                }
                token += 1;
                if (enum_info.enum_type_flags & .FLAGS) && token.type == .VERTICAL_SLASH
                {
                    token += 1;
                }
                else
                {
                    break;
                }
            }
            signed := enum_info.internal_type.signed;
            if signed
            {
                if      info.runtime_size == 1 { v := cast(s8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast(s16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast(s32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast(s64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }
            else
            {
                if value < 0  
                {
                    return null, false, error(first_enum_token, "Setting negative value (%) on unsigned member", value);
                }
                if      info.runtime_size == 1 { v := cast(u8)  value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 2 { v := cast(u16) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 4 { v := cast(u32) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else if info.runtime_size == 8 { v := cast(u64) value; memcpy(value_pointer, *v, size_of(type_of(v))); }
                else assert(false);
            }



            case .POINTER;
            pointer_info := cast(*Type_Info_Pointer)info;
            alloc_success, pointer_to_fill := parser_alloc(*settings, pointer_info.pointer_to, 1);
            if !alloc_success
            {
                return null, false, error(token, "Found a pointer type to fill but we couldn't allocate memory for it");
            }
            {
                struct_info := cast(*Type_Info_Struct)pointer_info.pointer_to;
                if pointer_info.pointer_to.type == .STRUCT && struct_info.initializer
                    struct_info.initializer(pointer_to_fill);
                else
                    memset(pointer_to_fill, 0, pointer_info.pointer_to.runtime_size);
            }
            successful_parse : bool;
            pointer_parse_error : string;
            token, successful_parse, pointer_parse_error = parse_one(token, pointer_info.pointer_to, pointer_to_fill, settings, custom_parsers);
            if !successful_parse then return token, false, pointer_parse_error;
            assert(info.runtime_size == size_of(type_of(pointer_to_fill)));
            memcpy(value_pointer, *pointer_to_fill, size_of(type_of(pointer_to_fill)));



            case .ARRAY;
            array_info := cast(*Type_Info_Array) info;

            indicated_size_on_file := -1;
            if token.type == .INTEGER
            {
                value, integer_parse_success, integer_parse_error := token_to_integer(token);
                if !integer_parse_success then return null, false, error(token, "Couldn't parse integer number: %\n", integer_parse_error);
                if value < 0
                    return null, false, error(token, "Requested array to have negative size '%', ignoring", value);
                else
                    indicated_size_on_file = cast(s64)value;
                token += 1;
            }
            if token.type != .OPEN_BRACKETS
            {
                return null, false, error(token, "Expected Opening Bracket '[' but found %", token.type);
            }
            token += 1;

            static_size := -1;
            if #complete array_info.array_type ==
            {
                case .FIXED;
                static_size = array_info.array_count;
                if indicated_size_on_file != -1 && static_size != indicated_size_on_file
                {
                    return null, false, error(token, "Indicated size on file (%) is different than the size of the fixed array (%)", indicated_size_on_file, static_size);
                }

                case .VIEW; #through;
                case .RESIZABLE;
                assert(array_info.array_count == -1, "Unexpected array count");
            }

            array_data : Resizable_Array; 
            if static_size != -1
            {
                array_data.data = value_pointer;
                array_data.allocated = static_size;
            }
            else if indicated_size_on_file != -1
            {
                alloc_success := false;
                alloc_success, array_data.data = parser_alloc(*settings, array_info.element_type, indicated_size_on_file);
                if !alloc_success
                {
                    return null, false, error(token, "Dynamic array wants to allocate % elements but we weren't able to", indicated_size_on_file);
                }
                array_data.allocated = indicated_size_on_file;
                {
                    struct_info := cast(*Type_Info_Struct)array_info.element_type;
                    if array_info.element_type.type == .STRUCT && struct_info.initializer
                        for index : 0..array_data.allocated-1
                            struct_info.initializer(array_data.data + (index * array_info.element_type.runtime_size));
                    else
                        memset(array_data.data, 0, array_data.allocated * array_info.element_type.runtime_size);
                }
            }
            while true
            {
                if token.type == .CLOSE_BRACKETS break;

                if array_data.count >= array_data.allocated
                {
                    if static_size != -1
                    {
                        return null, false, error(token, "Trying to add too many elements to static array of size %\n", static_size);
                    }
                    else if indicated_size_on_file != -1
                    {
                        return null, false, error(token, "Indicated size on file was '%' but more elements are present on the file", indicated_size_on_file);
                    }

                    old_allocated := array_data.allocated;
                    new_allocated := max(8, old_allocated * 2);
                    realloc_success := false;
                    realloc_success, array_data.data = parser_realloc(*settings, array_info.element_type, new_allocated, old_allocated, array_data.data);
                    if !realloc_success
                    {
                        return null, false, error(token, "Dynamic array wants to grow from % to % elements but we weren't able to reallocate them", old_allocated, new_allocated);
                    }
                    array_data.allocated = new_allocated;
                    {
                        struct_info := cast(*Type_Info_Struct)array_info.element_type;
                        if array_info.element_type.type == .STRUCT && struct_info.initializer
                            for index : old_allocated..array_data.allocated-1
                                struct_info.initializer(array_data.data + (index * array_info.element_type.runtime_size));
                        else
                            memset(array_data.data + (old_allocated * array_info.element_type.runtime_size), 0, (array_data.allocated - old_allocated) * array_info.element_type.runtime_size);
                    }
                }

                pointer_to_current := array_data.data + (array_data.count * array_info.element_type.runtime_size);
                successful_parse : bool;
                array_element_parse_error : string;
                token, successful_parse, array_element_parse_error = parse_one(token, array_info.element_type, pointer_to_current, settings, custom_parsers);
                if !successful_parse then return token, false, array_element_parse_error;
                array_data.count += 1;
                if token.type == .COMMA then token += 1;
            }
            if indicated_size_on_file != -1 && array_data.count != indicated_size_on_file
            {
                return null, false, error(token, "Indicated size on file was '%' but only '%' elements present on the file", indicated_size_on_file, array_data.count);
            }
            if #complete array_info.array_type ==
            {
                case .FIXED;
                assert(static_size >= 0);
                if array_data.count != static_size
                {
                    return null, false, error(token, "Not enough elements provided (%) for array of static size %", array_data.count, static_size);
                }
                size := array_data.count * array_info.element_type.runtime_size;
                assert(info.runtime_size == size);
                memcpy(value_pointer, array_data.data, size);

                case .VIEW;
                array_view : Array_View_64;
                array_view.count = array_data.count;
                array_view.data = array_data.data;
                assert(info.runtime_size == size_of(type_of(array_view)));
                memcpy(value_pointer, *array_view, size_of(type_of(array_view)));

                case .RESIZABLE;
                assert(info.runtime_size == size_of(type_of(array_data)));
                memcpy(value_pointer, *array_data, size_of(type_of(array_data)));
            }
            token += 1;



            case .STRUCT;
            struct_info := cast(*Type_Info_Struct) info;

            handled_by_custom_parsing := false;
            for custom_parsers
            {
                handled_by_custom_parsing=, next_token, error_message := it(token, struct_info, value_pointer);
                if error_message
                {
                    return null, false, error(token, "Error during custom parsing: %", error_message);
                }
                if handled_by_custom_parsing
                {
                    token = next_token;
                    break;
                }
            }
            if !handled_by_custom_parsing
            {
                if !is_first_call 
                {
                    if token.type != .OPEN_BRACES
                    {
                        return null, false, error(token, "Expected Opening Brace '{' but found %", token.type);
                    }
                    token += 1;
                }
                while true
                {
                    if !is_first_call
                    {
                        if token.type == .CLOSE_BRACES
                        {
                            token += 1;
                            break;
                        }
                    }
                    else
                    {
                        if token.type == .END  break;
                    }

                    if token.type != .IDENTIFIER
                    {
                        return null, false, error(token, "Expected identifier but found % instead", token.type);
                    } 
                    member_name := token.text;
                    token += 1;
                    if token.type != .EQUALS
                    {
                        return null, false, error(token, "Expected equals but found % instead", token.type);
                    }
                    token += 1;
                    
                    find_member :: (name : string, struct_info : *Type_Info_Struct) -> *Type_Info, total_offset : int
                    {
                        for * struct_info.members
                        {
                            if it.flags & .CONSTANT  
                                continue;
                            else if name == it.name
                                return it.type, it.offset_in_bytes;
                            else if it.flags & .USING && it.type.type == .STRUCT
                            {
                                type, offset := find_member(name, cast(*Type_Info_Struct) it.type);
                                if type then return type, (offset + it.offset_in_bytes);
                            }
                            //
                            // @@NOTE: This won't chase 'using' pointers.
                            //
                        }
                        return null, 0;
                    }

                    contained_type, offset_in_bytes := find_member(member_name, struct_info);
                    if !contained_type
                    {
                        return null, false, error(token, "Didn't find member '%' in struct '%' to fill in", member_name, struct_info.name);
                    }
                    member_pointer := value_pointer;
                    member_pointer += offset_in_bytes;
                    successful_parse : bool;
                    member_parse_error : string;
                    token, successful_parse, member_parse_error = parse_one(token, contained_type, member_pointer, settings, custom_parsers);
                    if !successful_parse then return token, false, member_parse_error;
                }
            }



            case .VARIANT;
            variant_info := cast(*Type_Info_Variant)info;
            successful_parse : bool;
            variant_parse_error : string;
            token, successful_parse, variant_parse_error = parse_one(token, variant_info.variant_of, value_pointer, settings, custom_parsers, is_first_call);
            if !successful_parse then return token, false, variant_parse_error;



            case .PROCEDURE;            #through;
            case .VOID;                 #through;
            case .OVERLOAD_SET;         #through;
            case .ANY;                  #through;
            case .POLYMORPHIC_VARIABLE; #through;
            case .TYPE;                 #through;
            case .CODE;
            return null, false, error(token, "Requesting parsing of unsupported type '%'", info.type);
        }
        return token, true, "";
    }

    tokenizer : Tokenizer;
    init_tokenizer(*tokenizer, the_string);
    tokens, tokenize_success, tokenize_error := tokenize_all_tokens(*tokenizer);
    if !tokenize_success then return false, tokenize_error;
    defer array_reset(*tokens);

    local_custom_parsers := NewArray(CUSTOM_PARSERS.count + settings.extra_custom_parsers.count, Custom_Parser,, temporary_allocator);
    for CUSTOM_PARSERS local_custom_parsers[it_index] = it; 
    for settings.extra_custom_parsers local_custom_parsers[CUSTOM_PARSERS.count + it_index] = it;

    token := tokens.data;
    while token && token.type != .END
    {
        successful_parse : bool;
        parse_error : string;
        token, successful_parse, parse_error = parse_one(token, result_type_info, result, settings, local_custom_parsers, is_first_call = true);
        if !successful_parse then return false, parse_error;
    }

    return true, "";
}



Unparse_Settings :: struct
{
    extra_custom_unparsers : []Custom_Unparser;
    // If you want a particular call to use further custom unparsing procedures in addition
    // to the ones in the module parameters, you can specify them here.

    float_output_mode : enum
    { 
        FLOAT_ONLY;          // 1.0
        BINARY_ONLY;         // #0x3ff0000000000000
        BINARY_WITH_COMMENT; // #0x3ff0000000000000 /*+1.000000*/
    } = .FLOAT_ONLY;
    // This controls the different ways to output floating point numbers. With a balance
    // of readability, modifiability, precission and speed or parsing.
}

Custom_Unparser :: #type (builder : *String_Builder, struct_info : *Type_Info_Struct, value_pointer : *void) -> unparsed : bool, error : string;

unparse :: (builder : *String_Builder, input : *$Input_Type, settings := Unparse_Settings.{}) -> success : bool, error : string
{
    success, error := unparse(builder, input, type_info(Input_Type), settings);
    return success, error;
}
unparse :: (builder : *String_Builder, input : *void, input_type_info : *Type_Info_Struct, settings := Unparse_Settings.{}) -> success : bool, error : string
{
    unparse_one :: (builder : *String_Builder, info : *Type_Info, value_pointer : *void, depth : int, settings : Unparse_Settings, custom_unparsers : []Custom_Unparser, brackets_on_struct := true) -> success : bool #must, error : string #must
    {
        append_indentation :: (builder : *String_Builder, depth : int)
        {
            for 0..depth-1 append(builder, "    ");
        }

        if #complete info.type == 
        {
            case .INTEGER;
            format : FormatInt;
            format.value.type = info;
            format.value.value_pointer = value_pointer;
            print_integer(builder, format);



            case .FLOAT;
            float_value_as_f64 : float64;
            trailing_width := 6;
            if      info.runtime_size == 4 { trailing_width = 6;  float_value_as_f64 = cast(float64)(cast(*float32)value_pointer).*; }
            else if info.runtime_size == 8 { trailing_width = 12; float_value_as_f64 =              (cast(*float64)value_pointer).*; }
            else assert(false);
            float_value_as_u64 := (cast(*u64)*float_value_as_f64).*;
            format_float := FormatFloat.{ value = float_value_as_f64, trailing_width = trailing_width, zero_removal = .NO, positive_number_prefix = .PLUS }; 
            format_int := FormatInt.{ value = float_value_as_u64, base = 16 , minimum_digits = 16 };
            if #complete settings.float_output_mode ==
            {
                case .FLOAT_ONLY;
                print_float(builder, format_float);

                case .BINARY_ONLY;
                append(builder, "#0x");
                print_integer(builder, format_int);

                case .BINARY_WITH_COMMENT;
                append(builder, "#0x");
                print_integer(builder, format_int);
                append(builder, " /*");
                print_float(builder, format_float);
                append(builder, "*/");
            }



            case .BOOL;
            if (cast(*bool)value_pointer).* then append(builder, "true"); else append(builder, "false");



            case .STRING;
            the_string := (cast(*string)value_pointer).*;
            append(builder, "\"");
            append(builder, the_string);
            append(builder, "\"");



            case .POINTER;
            pointer_info := cast(*Type_Info_Pointer)info;
            the_pointer := (cast(**void)value_pointer).*;
            successful_pointer_unparse, pointer_unparse_error := unparse_one(builder, pointer_info.pointer_to, the_pointer, depth, settings, custom_unparsers);
            if !successful_pointer_unparse then return false, pointer_unparse_error;



            case .STRUCT;
            struct_info := cast(*Type_Info_Struct)info;
            default_value := talloc(struct_info.runtime_size);
            if struct_info.initializer then struct_info.initializer(default_value); else memset(default_value, 0, struct_info.runtime_size);

            handled_by_custom_parsing := false;
            for custom_unparsers
            {
                handled_by_custom_parsing=, error_message := it(builder, struct_info, value_pointer);
                if error_message then return false, tprint("Error during custom unparsing: %", error_message); 
                if handled_by_custom_parsing then break;
            }
            if !handled_by_custom_parsing
            {
                added_any_members := false;
                if brackets_on_struct then append(builder, "{");
                max_member_offset_written := -1;
                for member : struct_info.members
                {
                    if !(member.flags & .CONSTANT)
                    {
                        if member.offset_in_bytes > max_member_offset_written
                        {
                            max_member_offset_written = member.offset_in_bytes + max(member.type.runtime_size - 1, 0);
                            member_value_pointer := value_pointer + member.offset_in_bytes;
                            is_default := memcmp(member_value_pointer, default_value + member.offset_in_bytes, member.type.runtime_size) == 0;
                            if !is_default
                            {
                                if !added_any_members
                                {
                                    added_any_members = true;
                                    if brackets_on_struct then append(builder, "\n");
                                }
                                if (member.flags & .USING)
                                {
                                    successful_member_unparse, member_unparse_error := unparse_one(builder, member.type, member_value_pointer, depth, settings, custom_unparsers, brackets_on_struct = false);
                                    if !successful_member_unparse then return false, member_unparse_error;
                                }
                                else
                                {
                                    append_indentation(builder, depth);
                                    append(builder, member.name);
                                    append(builder, " = ");
                                    successful_member_unparse, member_unparse_error := unparse_one(builder, member.type, member_value_pointer, depth + 1, settings, custom_unparsers);
                                    if !successful_member_unparse then return false, member_unparse_error;
                                    append(builder, "\n");
                                }
                            }
                        }
                    }
                }
                if brackets_on_struct
                {
                    if added_any_members then append_indentation(builder, depth - 1);
                    append(builder, "}");
                }
            }


                
            case .ARRAY;
            array_info := cast(*Type_Info_Array)info;
            array_view := cast(*Array_View_64)value_pointer;
            print_integer(builder, FormatInt.{ value = array_view.count });
            append(builder, " [\n");
            line_break_every_n_elements := 1;
            if array_info.element_type.type == 
            {
                case .INTEGER; line_break_every_n_elements = 10;
                case .FLOAT;   line_break_every_n_elements = 3;
                case .BOOL;    line_break_every_n_elements = 15;
                case .STRING;  line_break_every_n_elements = 5;
                case .ENUM;    line_break_every_n_elements = 10;
            }
            for 0..array_view.count-1
            {
                if it == 0 || (max(it-1, 0) % line_break_every_n_elements) == (line_break_every_n_elements-1) then append_indentation(builder, depth);
                array_element_value_pointer := array_view.data + (array_info.element_type.runtime_size * it);
                successful_element_unparse, element_unparse_error := unparse_one(builder, array_info.element_type, array_element_value_pointer, depth + 1, settings, custom_unparsers);
                if !successful_element_unparse then return false, element_unparse_error;
                if it == array_view.count-1 || (it % line_break_every_n_elements) == (line_break_every_n_elements-1) then append(builder, ",\n"); else append(builder, ", ");
            }
            append_indentation(builder, depth - 1);
            append(builder, "]");



            case .ENUM;
            enum_info := cast(*Type_Info_Enum)info;
            enum_value : s64;
            if      info.runtime_size == 1 { enum_value = cast(s64)(cast(*s8) value_pointer).*; }
            else if info.runtime_size == 2 { enum_value = cast(s64)(cast(*s16)value_pointer).*; }
            else if info.runtime_size == 4 { enum_value = cast(s64)(cast(*s32)value_pointer).*; }
            else if info.runtime_size == 8 { enum_value = cast(s64)(cast(*s64)value_pointer).*; }
            else assert(false);
            if (enum_info.enum_type_flags & .FLAGS)
            {
                written_flags := 0;
                for enum_info.values
                {
                    if (enum_value & it) == it
                    {
                        if written_flags != 0 then append(builder, " | "); 
                        append(builder, enum_info.names[it_index]);
                        written_flags |= it;
                    }
                }
                remaining := enum_value & ~written_flags;
                if remaining != 0
                {
                    if written_flags != 0 then append(builder, " | "); 
                    append(builder, "0x");
                    print_integer(builder, FormatInt.{ value = remaining, base = 16 });
                    written_flags |= remaining;
                }
            }
            else
            {
                found := false;
                for enum_info.values
                {
                    if enum_value == it
                    {
                        append(builder, enum_info.names[it_index]);
                        found = true;
                        break;
                    }
                }
                if !found
                {
                    format : FormatInt;
                    format.value.type = enum_info.internal_type;
                    format.value.value_pointer = value_pointer;
                    print_integer(builder, format);
                }
            }



            case .VARIANT;
            variant_info := cast(*Type_Info_Variant)info;
            successful_variant_unparse, variant_unparse_error := unparse_one(builder, variant_info.variant_of, value_pointer, depth, settings, custom_unparsers);
            if !successful_variant_unparse then return false, variant_unparse_error;



            case .PROCEDURE;            #through;
            case .VOID;                 #through;
            case .OVERLOAD_SET;         #through;
            case .ANY;                  #through;
            case .POLYMORPHIC_VARIABLE; #through;
            case .TYPE;                 #through;
            case .CODE;
            return false, tprint("Requesting unparsing of unsupported type '%'", info.type);
        }

        return true, "";
    }

    local_custom_unparsers := NewArray(CUSTOM_UNPARSERS.count + settings.extra_custom_unparsers.count, Custom_Unparser,, temporary_allocator);
    for CUSTOM_UNPARSERS local_custom_unparsers[it_index] = it; 
    for settings.extra_custom_unparsers local_custom_unparsers[CUSTOM_UNPARSERS.count + it_index] = it;

    successful_unparse, unparse_error := unparse_one(builder, input_type_info, input, depth = 0, settings, local_custom_unparsers, brackets_on_struct = false);
    if !successful_unparse then return false, unparse_error;

    return true, "";
}



#scope_file



parser_alloc :: (settings : *Parse_Settings, info : *Type_Info, size : int) -> bool, *void
{
    for settings.allocators
    {
        handled, result := it.procedure(info, size, 0, null, it.data);
        if handled then return true, result;
    }
    return false, null;
}

parser_realloc :: (settings : *Parse_Settings, info : *Type_Info, size : int, old_size : int, old_memory : *void) -> bool, *void
{
    for settings.allocators
    {
        handled, result := it.procedure(info, size, old_size, old_memory, it.data);
        if handled then return true, result;
    }
    return false, null;
}


