
$(document).ready(function() {
 $(".exp_filter").toggle(
      function () {
        $(this).addClass("selected");
        $(".f_popup").addClass("visib");
      },
      function () {
        $(this).removeClass("selected");
        $(".f_popup").removeClass("visib");  
      }
  );
});

$(document).ready( function() {
//
// Enable selectBox control and bind events
//
$("#create").click( function() {
$(".selectBox").selectBox();
});
$("#destroy").click( function() {
$(".selectBox").selectBox('destroy');
});
$("#enable").click( function() {
$(".selectBox").selectBox('enable');
});
$("#disable").click( function() {
$(".selectBox").selectBox('disable');
});
$("#serialize").click( function() {
$("#console").append('<br />-- Serialized data --<br />' + $("FORM").serialize().replace(/&/g, '<br />') + '<br /><br />');
$("#console")[0].scrollTop = $("#console")[0].scrollHeight;
});
$("#value-1").click( function() {
$(".selectBox").selectBox('value', 1);
});
$("#value-2").click( function() {
$(".selectBox").selectBox('value', 2);
});
$("#value-2-4").click( function() {
$(".selectBox").selectBox('value', [2, 4]);
});
$("#options").click( function() {
$(".selectBox").selectBox('options', {
'Opt Group 1': {
'1': 'Value 1',
'2': 'Value 2',
'3': 'Value 3',
'4': 'Value 4',
'5': 'Value 5'
},
'Opt Group 2': {
'6': 'Value 6',
'7': 'Value 7',
'8': 'Value 8',
'9': 'Value 9',
'10': 'Value 10'
},
'Opt Group 3': {
'11': 'Value 11',
'12': 'Value 12',
'13': 'Value 13',
'14': 'Value 14',
'15': 'Value 15'
}
});
});
$("#default").click( function() {
$(".selectBox").selectBox('settings', {
'menuTransition': 'default',
'menuSpeed' : 0
});
});
$("#fade").click( function() {
$(".selectBox").selectBox('settings', {
'menuTransition': 'fade',
'menuSpeed' : 'fast'
});
});
$("#slide").click( function() {
$(".selectBox").selectBox('settings', {
'menuTransition': 'slide',
'menuSpeed' : 'fast'
});
});
$(".selectBox")
.selectBox()
.focus( function() {
$("#console").append('Focus on ' + $(this).attr('name') + '<br />');
$("#console")[0].scrollTop = $("#console")[0].scrollHeight;
})
.blur( function() {
$("#console").append('Blur on ' + $(this).attr('name') + '<br />');
$("#console")[0].scrollTop = $("#console")[0].scrollHeight;
})
.change( function() {
$("#console").append('Change on ' + $(this).attr('name') + ': ' + $(this).val() + '<br />');
$("#console")[0].scrollTop = $("#console")[0].scrollHeight;
});

$(function(){

	$('input').checkBox();
		
		$('#toggle-all').click(function(){
		$('#example input[type=checkbox]').checkBox('toggle');
		return false;
	});
	
	$('#check-all').click(function(){
		$('#example input[type=checkbox]').checkBox('changeCheckStatus', true);
		return false;
	});

	$('#uncheck-all').click(function(){
		$('#example input[type=checkbox]').checkBox('changeCheckStatus', false);
		return false;
	});

});



});
