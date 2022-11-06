import { HttpClient } from '@angular/common/http';
import { AfterViewInit, Component, OnInit, ViewChild } from '@angular/core';
import { Observable } from 'rxjs';
import { debounceTime, tap, switchMap, finalize, distinctUntilChanged, filter } from 'rxjs/operators';
import { FormControl } from '@angular/forms';
import { Conversation } from '../conversation.service';

@Component({
  selector: 'app-search',
  templateUrl: './search.component.html',
  styleUrls: ['./search.component.scss']
})
export class SearchComponent implements OnInit {

  searchConversationsCtrl = new FormControl();
  filteredConversations: Conversation[];
  isLoading = false;
  errorMsg!: string;
  minLengthTerm = 3;
  conversation: Conversation | null;
  searchInput = "";

  constructor(
    private http: HttpClient
  ) { }

  onSelected() {
    this.conversation = this.searchInput as any;
    this.searchInput = null;
  }

  displayWith(value: any) {
    return value?.Title;
  }

  clearSelection() {
    this.conversation = null;
    this.filteredConversations = [];
  }

  ngOnInit() {
    this.searchConversationsCtrl.valueChanges
      .pipe(
        filter(res => {
          return res !== null && res.length >= this.minLengthTerm
        }),
        distinctUntilChanged(),
        debounceTime(100),
        tap(() => {
          this.errorMsg = "";
          this.filteredConversations = [];
          this.isLoading = true;
        }),
        switchMap(value => this.http.get('http://localhost:5000/api/search/' + value)
          .pipe(
            finalize(() => {
              this.isLoading = false
            }),
          )
        )
      )
      .subscribe((data: any) => {
          this.filteredConversations = data.items;
      });
  }


  displayDocument(blobUrl: string) {
    throw new Error(blobUrl);
  }

  getDisplay(conversation : Conversation) : string 
  {
    if (!(this.searchInput as string))
      return "no search";
    var match = conversation.dataPoints.filter(dp => dp.content && dp.content.toLowerCase().indexOf(this.searchInput?.toLowerCase()) >= 0);
    if (!match || !match.length)
      return "";
    return match[0].content
  }

  url : any;


/**
* Method is use to download file.
* @param data - Array Buffer data
* @param type - type of the document.
*/
downLoadFile(data: any, type: string) {
  let blob = new Blob([data], { type: type});
  let url = window.URL.createObjectURL(blob);
//  this.url = this.sanitization.bypassSecurityTrustUrl(url);
 // let pwa = window.open(url);
//  if (!pwa || pwa.closed || typeof pwa.closed == 'undefined') {
//      alert( 'Please disable your Pop-up blocker and try again.');
 // }
}
}


