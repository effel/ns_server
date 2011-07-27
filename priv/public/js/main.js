

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
