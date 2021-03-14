import { HttpClient } from '@angular/common/http';
import { AfterViewInit, Component, OnInit, ViewChild } from '@angular/core';
import { SearchFieldComponent, SearchFieldDataSource, SearchFieldResult } from 'ngx-mat-search-field';
import { Observable } from 'rxjs';
import { environment } from 'src/environments/environment';
import { ConversationService } from '../conversation.service';
import { DomSanitizer} from '@angular/platform-browser';

@Component({
  selector: 'app-search',
  templateUrl: './search.component.html',
  styleUrls: ['./search.component.scss']
})
export class SearchComponent implements OnInit,AfterViewInit {

  searchFieldDataSource: SearchFieldDataSource;
  @ViewChild('searchBar') searchBar : SearchFieldComponent;

  constructor(private conversationService: ConversationService, private http : HttpClient,private sanitization:DomSanitizer) {
    this.searchFieldDataSource = {
      search(search: string, size: number, skip: number): Observable<SearchFieldResult> {
        return conversationService.getConversations(search, size, skip);
      }
    };
  }

  ngOnInit(): void {
    /*this.http.get(`https://localhost:5001/api/storage/d5558e2337634619a79d4303b17173f8.jpeg`,{
      responseType: 'arraybuffer'} 
     ).subscribe(response => this.downLoadFile(response, "image/jpg"));*/
  }

  ngAfterViewInit():void{
    const urlPrefix = "onlineUrl-";
    this.searchBar.registerOnChange((data:string)=>{
      if(data.startsWith(urlPrefix))
      {
        this.displayDocument(data.substring(urlPrefix.length));
      }
    });
  }

  displayDocument(blobUrl: string) {
    throw new Error(blobUrl);
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
  this.url = this.sanitization.bypassSecurityTrustUrl(url);
 // let pwa = window.open(url);
//  if (!pwa || pwa.closed || typeof pwa.closed == 'undefined') {
//      alert( 'Please disable your Pop-up blocker and try again.');
 // }
}
}
